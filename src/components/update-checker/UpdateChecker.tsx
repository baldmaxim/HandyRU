import React, { useState, useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { check, type Update } from "@tauri-apps/plugin-updater";
import { relaunch } from "@tauri-apps/plugin-process";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { openUrl } from "@tauri-apps/plugin-opener";
import { arch, platform } from "@tauri-apps/plugin-os";
import {
  isPermissionGranted,
  requestPermission,
  sendNotification,
} from "@tauri-apps/plugin-notification";
import { toast } from "sonner";
import { useSettings } from "../../hooks/useSettings";
import { commands } from "../../bindings";
import { useUpdateStore, type UpdateStage } from "../../stores/updateStore";
import {
  resolvePortableInstallerUrl,
  PORTABLE_RELEASES_URL,
} from "./portableInstaller";

// The app lives in the tray for days, so re-check periodically, not only at
// launch, and again whenever the settings window is brought up after a while.
const CHECK_INTERVAL_MS = 60 * 60 * 1000;
const FOCUS_RECHECK_MS = 10 * 60 * 1000;

const notify = async (title: string, body: string) => {
  try {
    let granted = await isPermissionGranted();
    if (!granted) granted = (await requestPermission()) === "granted";
    if (granted) sendNotification({ title, body });
  } catch (error) {
    console.error("Failed to send update notification:", error);
  }
};

/**
 * Background updater: checks on a schedule, downloads silently, then offers the
 * install in a toast (and a system notification while the window is hidden). It
 * renders nothing but the portable-install dialog; the status and the manual
 * check live in the shared update store (see the About page).
 */
const UpdateChecker: React.FC = () => {
  const { t } = useTranslation();
  const setIsChecking = (isChecking: boolean) =>
    useUpdateStore.setState({ isChecking });
  const setShowUpToDate = (showUpToDate: boolean) =>
    useUpdateStore.setState({ showUpToDate });
  const setDownloadProgress = (progress: number) =>
    useUpdateStore.setState({ progress });
  const [showPortableUpdateDialog, setShowPortableUpdateDialog] =
    useState(false);
  const [portableInstallerUrl, setPortableInstallerUrl] = useState<string>(
    PORTABLE_RELEASES_URL,
  );

  const { settings, isLoading, updateChecksLocked } = useSettings();
  // Wait for the lock state too (null = not loaded yet), otherwise the first
  // render could fire an update check before HANDY_DISABLE_UPDATER is known.
  const settingsLoaded =
    !isLoading && settings !== null && updateChecksLocked !== null;
  // Forced-off by system configuration (HANDY_DISABLE_UPDATER) overrides the
  // stored preference without persisting it, mirroring the backend's effective
  // updater state.
  const updateChecksEnabled =
    (settings?.update_checks_enabled ?? false) && updateChecksLocked === false;

  const upToDateTimeoutRef = useRef<ReturnType<typeof setTimeout>>();
  // Mirrors `stage` for the interval/event callbacks, which would otherwise
  // read a stale render's state.
  const stageRef = useRef<UpdateStage>("idle");
  const checkingRef = useRef(false);
  // The downloaded update; its bytes stay in memory until install().
  const updateRef = useRef<Update | null>(null);
  const notifiedVersionRef = useRef("");
  const lastCheckRef = useRef(0);

  const moveTo = (next: UpdateStage) => {
    stageRef.current = next;
    useUpdateStore.setState({ stage: next });
  };

  useEffect(() => {
    // Wait for settings to load before doing anything
    if (!settingsLoaded) return;

    useUpdateStore.setState({
      enabled: updateChecksEnabled,
      checkNow: () => checkForUpdates(true),
      install: () =>
        stageRef.current === "available"
          ? setShowPortableUpdateDialog(true)
          : installUpdate(),
    });

    if (!updateChecksEnabled) {
      if (upToDateTimeoutRef.current) {
        clearTimeout(upToDateTimeoutRef.current);
      }
      setIsChecking(false);
      setShowUpToDate(false);
      return;
    }

    checkForUpdates(false);
    const interval = setInterval(
      () => checkForUpdates(false),
      CHECK_INTERVAL_MS,
    );

    // Listen for update check events
    const updateUnlisten = listen("check-for-updates", () => {
      checkForUpdates(true);
    });
    const focusUnlisten = getCurrentWindow().onFocusChanged(
      ({ payload: focused }) => {
        if (focused && Date.now() - lastCheckRef.current > FOCUS_RECHECK_MS) {
          checkForUpdates(false);
        }
      },
    );

    return () => {
      clearInterval(interval);
      focusUnlisten.then((fn) => fn());
      if (upToDateTimeoutRef.current) {
        clearTimeout(upToDateTimeoutRef.current);
      }
      updateUnlisten.then((fn) => fn());
    };
  }, [settingsLoaded, updateChecksEnabled]);

  const flashUpToDate = () => {
    setShowUpToDate(true);
    if (upToDateTimeoutRef.current) {
      clearTimeout(upToDateTimeoutRef.current);
    }
    upToDateTimeoutRef.current = setTimeout(() => {
      setShowUpToDate(false);
    }, 3000);
  };

  // Downloads in the background as soon as an update is found, then tells the
  // user once per version; installing waits for their click, since it restarts
  // the app and could cut off a dictation.
  const downloadUpdate = async (update: Update) => {
    moveTo("downloading");
    setDownloadProgress(0);
    let downloaded = 0;
    let contentLength = 0;
    try {
      await update.download((event) => {
        switch (event.event) {
          case "Started":
            contentLength = event.data.contentLength ?? 0;
            break;
          case "Progress":
            downloaded += event.data.chunkLength;
            setDownloadProgress(
              contentLength > 0
                ? Math.min(100, Math.round((downloaded / contentLength) * 100))
                : 0,
            );
            break;
        }
      });
      updateRef.current = update;
      moveTo("ready");
      if (notifiedVersionRef.current !== update.version) {
        notifiedVersionRef.current = update.version;
        void notify(
          t("footer.updateReadyTitle", { version: update.version }),
          t("footer.updateReadyBody"),
        );
        // Stays up until acted on, so it's still there when the user opens the
        // window from the tray after the system notification.
        toast(t("footer.updateReadyTitle", { version: update.version }), {
          id: "update-ready",
          description: t("footer.updateReadyToast"),
          duration: Infinity,
          action: {
            label: t("footer.installNow"),
            onClick: () => installUpdate(),
          },
          cancel: { label: t("footer.later"), onClick: () => {} },
        });
      }
    } catch (error) {
      // Retried on the next periodic or manual check.
      console.error("Failed to download update:", error);
      moveTo("idle");
    } finally {
      setDownloadProgress(0);
    }
  };

  const checkForUpdates = async (manual: boolean) => {
    if (!updateChecksEnabled || checkingRef.current) return;
    // Already fetched or in flight: nothing new to learn until a restart.
    if (stageRef.current !== "idle") return;

    try {
      checkingRef.current = true;
      lastCheckRef.current = Date.now();
      setIsChecking(true);
      const update = await check();

      if (!update) {
        if (manual) flashUpToDate();
        return;
      }

      setShowUpToDate(false);
      useUpdateStore.setState({ version: update.version });

      if (await commands.isPortable()) {
        // Portable installs can't self-update in place — the manual dialog links
        // straight at the matching installer from this manifest instead.
        setPortableInstallerUrl(
          resolvePortableInstallerUrl(update.rawJson, platform(), arch()),
        );
        moveTo("available");
        if (notifiedVersionRef.current !== update.version) {
          notifiedVersionRef.current = update.version;
          void notify(
            t("footer.updateAvailableTitle", { version: update.version }),
            t("footer.updatePortableBody"),
          );
          toast(t("footer.updateAvailableTitle", { version: update.version }), {
            id: "update-ready",
            description: t("footer.updatePortableBody"),
            duration: Infinity,
            action: {
              label: t("footer.portableUpdateButton"),
              onClick: () => setShowPortableUpdateDialog(true),
            },
            cancel: { label: t("footer.later"), onClick: () => {} },
          });
        }
        return;
      }

      setIsChecking(false);
      await downloadUpdate(update);
    } catch (error) {
      console.error("Failed to check for updates:", error);
    } finally {
      checkingRef.current = false;
      setIsChecking(false);
    }
  };

  const installUpdate = async () => {
    const update = updateRef.current;
    if (!update) return;

    try {
      moveTo("installing");
      // On Windows this hands over to the installer, which exits the app.
      await update.install();
      await relaunch();
    } catch (error) {
      console.error("Failed to install update:", error);
      // install() consumes the downloaded bytes, so start over on next check.
      updateRef.current = null;
      moveTo("idle");
    }
  };

  // When no installer could be resolved for this target the button falls back to
  // the releases index, so the dialog has to say "browse" rather than "download".
  const hasDirectInstaller = portableInstallerUrl !== PORTABLE_RELEASES_URL;

  return (
    <>
      {showPortableUpdateDialog && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
          <div className="bg-background border border-mid-gray/20 rounded-lg p-6 max-w-md w-full mx-4 space-y-4">
            <h2 className="text-base font-semibold">
              {t("footer.portableUpdateTitle")}
            </h2>
            <p className="text-sm text-text/70">
              {hasDirectInstaller
                ? t("footer.portableUpdateMessage")
                : t("footer.portableUpdateBrowseMessage")}
            </p>
            <div className="flex gap-2 justify-end">
              <button
                className="px-3 py-1.5 text-sm rounded border border-mid-gray/20 hover:bg-mid-gray/10 transition-colors"
                onClick={() => setShowPortableUpdateDialog(false)}
              >
                {t("common.close")}
              </button>
              <button
                className="px-3 py-1.5 text-sm rounded bg-logo-primary text-white hover:bg-logo-primary/80 transition-colors"
                onClick={() => {
                  openUrl(portableInstallerUrl);
                  setShowPortableUpdateDialog(false);
                }}
              >
                {hasDirectInstaller
                  ? t("footer.portableUpdateButton")
                  : t("footer.portableUpdateBrowseButton")}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
};

export default UpdateChecker;
