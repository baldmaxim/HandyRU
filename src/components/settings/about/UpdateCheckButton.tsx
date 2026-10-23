import React from "react";
import { useTranslation } from "react-i18next";
import { useUpdateStore } from "@/stores/updateStore";
import { Button } from "../../ui/Button";

/** A manual "check for updates" control that also reflects the update state. */
export const UpdateCheckButton: React.FC = () => {
  const { t } = useTranslation();
  const {
    enabled,
    stage,
    version,
    progress,
    isChecking,
    showUpToDate,
    checkNow,
    install,
  } = useUpdateStore();

  if (!enabled) {
    return (
      <span className="text-sm text-text/60">
        {t("footer.updateCheckingDisabled")}
      </span>
    );
  }

  if (stage === "ready" || stage === "available") {
    return (
      <Button variant="primary" size="sm" onClick={install}>
        {stage === "ready"
          ? t("footer.restartToUpdate", { version })
          : t("footer.updateAvailableShort")}
      </Button>
    );
  }

  const busyLabel =
    stage === "downloading"
      ? progress > 0
        ? t("footer.downloading", { progress })
        : t("footer.preparing")
      : stage === "installing"
        ? t("footer.installing")
        : isChecking
          ? t("footer.checkingUpdates")
          : showUpToDate
            ? t("footer.upToDate")
            : null;

  return (
    <Button
      variant="secondary"
      size="sm"
      onClick={checkNow}
      disabled={busyLabel !== null}
      className="tabular-nums"
    >
      {busyLabel ?? t("settings.about.version.checkNow")}
    </Button>
  );
};
