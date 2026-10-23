import { listen } from "@tauri-apps/api/event";
import React, {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from "react";
import { useTranslation } from "react-i18next";
import "./RecordingOverlay.css";
import { commands, events } from "@/bindings";
import type {
  StreamPhase,
  StreamPhaseEvent,
  StreamTextEvent,
  StreamWorkKind,
} from "@/bindings";
import i18n, { syncLanguageFromSettings } from "@/i18n";
import type { ModelStateEvent } from "@/lib/types/events";
import { getLanguageDirection } from "@/lib/utils/rtl";
import OverlayIcon from "./OverlayIcon";
import OverlayWaveform from "./OverlayWaveform";

type OverlayState = "recording" | "streaming" | "transcribing" | "processing";

type EntrancePhase = "circle" | "pill" | "wave";

// Mic levels arrive as 16 FFT buckets; the scrolling waveform needs one level, so
// average the low/mid buckets where speech energy sits.
const LEVEL_BUCKETS = 12;

// Entrance choreography (OpenWhispr-style): the mark pops in as a circle and
// holds for a beat that reads as an acknowledged press, the circle grows into the
// pill, then the waveform fades in once the footprint has settled. Keep
// ENTRANCE_GROW_MS in sync with --ov-grow in RecordingOverlay.css.
const ENTRANCE_HOLD_MS = 260;
const ENTRANCE_GROW_MS = 300;
const WAVE_REVEAL_DELAY_MS = 100;

// Only call out a model load in the Live preview once it has run this long.
// Warm loads finish in well under this (~0.2s on Apple Silicon, ~1.5s on a
// Windows CPU backend), so the common case never flashes a loading notice while
// the user is speaking; cold loads can take 40s+.
const SLOW_MODEL_LOAD_MS = 2000;

const RecordingOverlay: React.FC = () => {
  const { t } = useTranslation();
  const [isVisible, setIsVisible] = useState(false);
  // Set by hide-overlay: the card plays its exit while the native window waits
  // out its hide delay (overlay.rs), instead of vanishing on the spot.
  const [leaving, setLeaving] = useState(false);
  const [entrance, setEntrance] = useState<EntrancePhase>("wave");
  const [state, setState] = useState<OverlayState>("recording");
  // `Stream::play()` returning does not mean hardware callbacks are flowing.
  // Stay visually in an arming state until the backend processes the first
  // actual microphone sample chunk.
  const [captureReady, setCaptureReady] = useState(false);
  // Recording starts while the model loads in the background. Say so, otherwise
  // a cold start looks like an empty Live preview that ignores speech, then a
  // hung "Transcribing..." spinner. Once recording stops, any in-flight load is
  // the wait, so the working label reflects it immediately; the Live notice
  // waits for the load to be slow so fast loads don't flash it mid-speech.
  const [modelLoading, setModelLoading] = useState(false);
  const [modelLoadSlow, setModelLoadSlow] = useState(false);
  const modelLoadTimerRef = useRef<ReturnType<typeof setTimeout>>();
  // Latched per Live session: once the loading notice has opened the panel, keep
  // it open after the load so it doesn't collapse and reopen when text arrives.
  const [loadNoticeShown, setLoadNoticeShown] = useState(false);
  const [streamText, setStreamText] = useState<StreamTextEvent>({
    committed: "",
    tentative: "",
  });
  const [phase, setPhase] = useState<StreamPhase>("listening");
  const [workKind, setWorkKind] = useState<StreamWorkKind>("transcribing");
  const [elapsed, setElapsed] = useState(0);
  // Bumped on each new recording/streaming session so the card remounts fresh
  // (replays the entrance, and never animates in from the previous panel's open
  // size).
  const [session, setSession] = useState(0);
  // Overlay placement (top vs bottom of the screen). The Live panel grows downward
  // from a top overlay (oldest line under the pill) and upward from a bottom one.
  const [position, setPosition] = useState<"top" | "bottom">("bottom");
  // True once live text overflows the cap. A top overlay fades its top edge only
  // while overflowing, so the resting first line stays crisp flush under the pill.
  const [overflowing, setOverflowing] = useState(false);

  // Written on every mic-level event, sampled by the waveform's own rAF loop, so
  // levels never re-render the overlay.
  const levelRef = useRef(0);
  // Live-text scroll-back: the text region "sticks" to the newest line while the
  // user is at the bottom; if they scroll up to read history, auto-follow pauses
  // until they scroll back down.
  const capRef = useRef<HTMLDivElement>(null);
  const pinnedRef = useRef(true);
  const direction = getLanguageDirection(i18n.language);

  useEffect(() => {
    const setupEventListeners = async () => {
      const unlistenShow = await listen("show-overlay", async (event) => {
        const overlayState = event.payload as OverlayState;
        // Reset synchronously before settings I/O. A fast microphone can emit
        // recording-ready while the awaits below are in flight; resetting after
        // them would overwrite that event and leave the overlay stuck arming.
        if (overlayState === "recording" || overlayState === "streaming") {
          setCaptureReady(false);
          levelRef.current = 0;
          setStreamText({ committed: "", tentative: "" });
        }

        await syncLanguageFromSettings();
        // The Live panel flows downward from a top overlay and upward from a
        // bottom one; read the placement so the layout can flip to match.
        try {
          const settings = await commands.getAppSettings();
          if (settings.status === "ok") {
            setPosition(
              settings.data.overlay_position === "top" ? "top" : "bottom",
            );
          }
        } catch {
          // Keep the previous/default placement if settings can't be read.
        }
        setState(overlayState);
        if (overlayState === "streaming") {
          setPhase("listening");
          setWorkKind("transcribing");
          setElapsed(0);
          setLoadNoticeShown(false);
        }
        if (overlayState === "recording" || overlayState === "streaming") {
          setEntrance("circle");
          setSession((s) => s + 1); // remount the card fresh for this session
        }
        setLeaving(false);
        setIsVisible(true);
      });

      const unlistenHide = await listen("hide-overlay", () => {
        setIsVisible(false);
        setLeaving(true);
        setCaptureReady(false);
      });

      const unlistenReady = await listen("recording-ready", () => {
        setElapsed(0);
        setCaptureReady(true);
      });

      const unlistenLevel = await listen<number[]>("mic-level", (event) => {
        const buckets = event.payload;
        let sum = 0;
        for (let i = 0; i < LEVEL_BUCKETS; i++) sum += buckets[i] || 0;
        // Light exponential smoothing; the waveform samples this every 80ms.
        levelRef.current = levelRef.current * 0.5 + (sum / LEVEL_BUCKETS) * 0.5;
      });

      const unlistenStream = await events.streamTextEvent.listen((event) => {
        setStreamText(event.payload);
      });

      const unlistenPhase = await events.streamPhaseEvent.listen((event) => {
        const payload: StreamPhaseEvent = event.payload;
        setPhase(payload.phase);
        if (payload.kind) setWorkKind(payload.kind);
      });

      // The backend ends every `loading_started` with exactly one of completed
      // or failed, so only those end a load. Other events (e.g. `unloaded` from
      // the idle watcher) aren't ordered against an in-flight load and must not
      // clear it.
      const unlistenModel = await listen<ModelStateEvent>(
        "model-state-changed",
        (event) => {
          const type = event.payload.event_type;
          if (type === "loading_started") {
            clearTimeout(modelLoadTimerRef.current);
            setModelLoading(true);
            setModelLoadSlow(false);
            modelLoadTimerRef.current = setTimeout(
              () => setModelLoadSlow(true),
              SLOW_MODEL_LOAD_MS,
            );
          } else if (
            type === "loading_completed" ||
            type === "loading_failed"
          ) {
            clearTimeout(modelLoadTimerRef.current);
            setModelLoading(false);
            setModelLoadSlow(false);
          }
        },
      );

      return () => {
        unlistenShow();
        unlistenHide();
        unlistenReady();
        unlistenLevel();
        unlistenStream();
        unlistenPhase();
        unlistenModel();
        clearTimeout(modelLoadTimerRef.current);
      };
    };

    setupEventListeners();
  }, []);

  // Elapsed capture timer starts only once microphone samples are flowing.
  useEffect(() => {
    if (state !== "streaming" || !isVisible || !captureReady) return;
    const id = setInterval(() => setElapsed((e) => e + 1), 1000);
    return () => clearInterval(id);
  }, [state, isVisible, captureReady]);

  // Stick to the bottom as text streams in — but only while pinned, so a user who
  // has scrolled up to read history isn't yanked back down by the next chunk.
  useLayoutEffect(() => {
    const el = capRef.current;
    if (!el) return;
    // Fade the top edge only once text actually overflows the cap.
    setOverflowing(el.scrollHeight > el.clientHeight + 1);
    if (pinnedRef.current) el.scrollTop = el.scrollHeight;
  }, [streamText]);

  // `session` re-runs this when a new Live session starts mid-load (e.g. a
  // retry during a cold load), since the reset doesn't change the other deps.
  useEffect(() => {
    if (modelLoadSlow && state === "streaming") setLoadNoticeShown(true);
  }, [modelLoadSlow, state, session]);

  // Each fresh streaming session starts pinned to the bottom, fade cleared.
  useEffect(() => {
    pinnedRef.current = true;
    setOverflowing(false);
  }, [session]);

  // Run the entrance timeline for each new session (show-overlay already reset
  // the phase to "circle" so the first frame is never the expanded pill).
  useEffect(() => {
    if (session === 0) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setEntrance("wave");
      return;
    }
    const grow = setTimeout(() => setEntrance("pill"), ENTRANCE_HOLD_MS);
    const reveal = setTimeout(
      () => setEntrance("wave"),
      ENTRANCE_HOLD_MS + ENTRANCE_GROW_MS + WAVE_REVEAL_DELAY_MS,
    );
    return () => {
      clearTimeout(grow);
      clearTimeout(reveal);
    };
  }, [session]);

  const getLevel = useCallback(() => levelRef.current, []);

  // Rendered through the exit too; only the never-shown overlay is empty.
  if (!isVisible && !leaving) return null;

  // Re-pin when the user is within ~a line of the bottom; unpin otherwise.
  const handleStreamScroll = () => {
    const el = capRef.current;
    if (!el) return;
    pinnedRef.current = el.scrollHeight - el.scrollTop - el.clientHeight <= 16;
  };

  const fmtTime = (s: number) =>
    `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;

  const transcribingLabel = modelLoading
    ? t("overlay.loadingModel")
    : t("overlay.transcribing");

  // ---- Shared building blocks (one visual language for every overlay form) ----
  const cancelBtn = (
    <button
      className="sx"
      aria-label="cancel"
      onClick={() => commands.cancelOperation()}
    >
      <svg viewBox="0 0 16 16" aria-hidden="true">
        <path
          d="M4 4 L12 12 M12 4 L4 12"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
        />
      </svg>
    </button>
  );

  // icon | waveform | timer + cancel. Every form keeps this one layout and the
  // card's width does the morphing: the card clips the row, so the icon glides
  // from the circle's centre to the pill's inset as it grows.
  const listeningRow = (showTimer: boolean) => (
    <div className="sbase">
      <OverlayIcon className="sicon" />
      <OverlayWaveform getLevel={getLevel} active={captureReady} />
      <div className="sbase-r">
        {showTimer && <span className="stimer">{fmtTime(elapsed)}</span>}
        {cancelBtn}
      </div>
    </div>
  );

  // icon (pulsing) | label | cancel — the icon is the same first child as in the
  // listening row, so React keeps its node across the switch.
  const workingRow = (label: string) => (
    <div className="sbase">
      <OverlayIcon className="sicon" />
      <span className="swork-label">{label}</span>
      <div className="sbase-r">{cancelBtn}</div>
    </div>
  );

  // The glow sits behind the card (the opaque card covers its centre), so only a
  // thin orbiting rim plus a soft halo show around whatever shape the card has.
  const stage = (
    cardClass: string,
    glow: boolean,
    children: React.ReactNode,
  ) => (
    <div className={`ov-stage ${position}`}>
      <div
        key={session}
        dir={direction}
        className={`sshell ${leaving ? "leaving" : ""}`}
      >
        <span className={`sglow ${glow ? "on" : ""}`} aria-hidden="true">
          <span className="sglow-ring">
            <span className="sglow-rotor" />
          </span>
        </span>
        <div className={`scard ${cardClass}`}>{children}</div>
      </div>
    </div>
  );

  const cardClasses = (flags: Record<string, boolean>) =>
    Object.keys(flags)
      .filter((name) => flags[name])
      .join(" ");

  // ---- Live overlay: a pill that sculpts open into a panel ----
  if (state === "streaming") {
    const hasText =
      streamText.committed.length > 0 || streamText.tentative.length > 0;
    const working = phase === "working";
    // While listening, a slow model load opens the panel with a notice where the
    // text would be, so speech that isn't transcribing yet doesn't look ignored.
    const loadingNotice = modelLoadSlow && !working && !hasText;
    // Keep the panel open whenever there's text — even while finalizing — so the
    // transcript stays put under a working label instead of collapsing and
    // squishing the text mid-stream.
    const open = hasText || loadingNotice || (loadNoticeShown && !working);
    // With nothing to keep on screen, finalizing folds back into the glowing
    // circle — unless a model load is the wait, which a labelled pill calls out.
    const labeled = working && !open && modelLoading;
    const circle = !open && !labeled && (working || entrance === "circle");

    return stage(
      cardClasses({
        open,
        circle,
        labeled,
        live: !working,
        busy: working,
        arming: !working && !captureReady,
        "wave-in": entrance === "wave",
      }),
      working && !open,
      <>
        <div className="stext">
          <div className="stext-clip">
            <div
              className={`stext-cap ${overflowing ? "overflowing" : ""}`}
              ref={capRef}
              onScroll={handleStreamScroll}
            >
              <p>
                {loadingNotice && (
                  <span className="sloading">{t("overlay.loadingModel")}</span>
                )}
                <span className="committed">
                  {streamText.committed ? streamText.committed + " " : ""}
                </span>
                <span className="tentative">{streamText.tentative}</span>
                {/* Drop the blinking caret once finalizing — it's no longer
                    capturing, and the pulsing mark conveys the work. */}
                {!working && !loadingNotice && <span className="scaret" />}
              </p>
            </div>
          </div>
        </div>
        {working
          ? workingRow(
              workKind === "polishing"
                ? t("overlay.processing")
                : transcribingLabel,
            )
          : listeningRow(open)}
      </>,
    );
  }

  // ---- Minimal overlay: the circle grows into the listening pill; finalizing
  // folds it back into a glowing circle (a labelled pill while a model loads).
  const working = state === "transcribing" || state === "processing";
  const workLabel =
    state === "processing" ? t("overlay.processing") : transcribingLabel;
  const labeled = working && modelLoading;

  return stage(
    cardClasses({
      circle: !labeled && (working || entrance === "circle"),
      labeled,
      live: !working,
      busy: working,
      arming: !working && !captureReady,
      "wave-in": entrance === "wave",
    }),
    working,
    working ? workingRow(workLabel) : listeningRow(false),
  );
};

export default RecordingOverlay;
