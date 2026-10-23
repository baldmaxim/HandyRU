import React, { useCallback, useState } from "react";
import { Check, Copy, PencilLine, RotateCcw, Star, Trash2 } from "lucide-react";
import { useTranslation } from "react-i18next";
import { toast } from "sonner";
import type { HistoryEntry } from "@/bindings";
import { formatDateTime } from "@/utils/dateFormat";
import { AudioPlayer } from "../../ui/AudioPlayer";
import { Button } from "../../ui/Button";

const IconButton: React.FC<{
  onClick: () => void;
  title: string;
  disabled?: boolean;
  active?: boolean;
  children: React.ReactNode;
}> = ({ onClick, title, disabled, active, children }) => (
  <button
    onClick={onClick}
    disabled={disabled}
    className={`p-1.5 rounded-md flex items-center justify-center transition-colors cursor-pointer disabled:cursor-not-allowed disabled:text-text/20 ${
      active
        ? "text-logo-primary hover:text-logo-primary/80"
        : "text-text/50 hover:text-logo-primary"
    }`}
    title={title}
  >
    {children}
  </button>
);

interface HistoryEntryProps {
  entry: HistoryEntry;
  onToggleSaved: () => void;
  onCopyText: (text: string) => Promise<boolean>;
  getAudioUrl: (fileName: string) => Promise<string | null>;
  deleteAudio: (id: number) => Promise<void>;
  retryTranscription: (id: number) => Promise<void>;
  saveCorrection: (id: number, text: string | null) => Promise<void>;
}

export const HistoryEntryItem: React.FC<HistoryEntryProps> = ({
  entry,
  onToggleSaved,
  onCopyText,
  getAudioUrl,
  deleteAudio,
  retryTranscription,
  saveCorrection,
}) => {
  const { t, i18n } = useTranslation();
  const [showCopied, setShowCopied] = useState(false);
  const [retrying, setRetrying] = useState(false);
  // Draft of the corrected text while editing; null when not editing.
  const [draft, setDraft] = useState<string | null>(null);
  const [savingCorrection, setSavingCorrection] = useState(false);

  // The corrected text, once given, is what the user meant to say.
  const displayText = entry.corrected_text ?? entry.transcription_text;
  const hasTranscription = displayText.trim().length > 0;
  const editing = draft !== null;
  const busy = retrying || savingCorrection;

  const handleLoadAudio = useCallback(
    () => getAudioUrl(entry.file_name),
    [getAudioUrl, entry.file_name],
  );

  const handleCopyText = async () => {
    if (!hasTranscription) {
      return;
    }

    const copied = await onCopyText(displayText);
    if (!copied) {
      toast.error(t("settings.history.copyError"));
      return;
    }

    setShowCopied(true);
    setTimeout(() => setShowCopied(false), 2000);
  };

  const handleDeleteEntry = async () => {
    try {
      await deleteAudio(entry.id);
    } catch (error) {
      console.error("Failed to delete entry:", error);
      toast.error(t("settings.history.deleteError"));
    }
  };

  const handleRetranscribe = async () => {
    try {
      setRetrying(true);
      await retryTranscription(entry.id);
    } catch (error) {
      console.error("Failed to re-transcribe:", error);
      toast.error(t("settings.history.retranscribeError"));
    } finally {
      setRetrying(false);
    }
  };

  // An empty draft, or one equal to the recognized text, clears the correction.
  const handleSaveCorrection = async () => {
    if (draft === null) return;
    try {
      setSavingCorrection(true);
      await saveCorrection(entry.id, draft.trim() || null);
      setDraft(null);
    } catch (error) {
      console.error("Failed to save correction:", error);
      toast.error(t("settings.history.correction.error"));
    } finally {
      setSavingCorrection(false);
    }
  };

  const handleDraftKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === "Escape") {
      setDraft(null);
    } else if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
      event.preventDefault();
      handleSaveCorrection();
    }
  };

  const formattedDate = formatDateTime(String(entry.timestamp), i18n.language);

  return (
    <div className="px-4 py-2 pb-5 flex flex-col gap-3">
      <div className="flex justify-between items-center">
        <div className="flex items-center gap-2">
          <p className="text-sm font-medium">{formattedDate}</p>
          {entry.corrected_text !== null && !editing && (
            <span
              className="text-xs px-1.5 py-0.5 rounded bg-logo-primary/15 text-logo-primary"
              title={entry.transcription_text}
            >
              {t("settings.history.correction.badge")}
            </span>
          )}
        </div>
        <div className="flex items-center">
          <IconButton
            onClick={handleCopyText}
            disabled={!hasTranscription || busy}
            title={t("settings.history.copyToClipboard")}
          >
            {showCopied ? (
              <Check width={16} height={16} />
            ) : (
              <Copy width={16} height={16} />
            )}
          </IconButton>
          <IconButton
            onClick={() => setDraft(displayText)}
            disabled={busy || editing}
            active={entry.corrected_text !== null}
            title={t("settings.history.correction.edit")}
          >
            <PencilLine width={16} height={16} />
          </IconButton>
          <IconButton
            onClick={onToggleSaved}
            disabled={busy}
            active={entry.saved}
            title={
              entry.saved
                ? t("settings.history.unsave")
                : t("settings.history.save")
            }
          >
            <Star
              width={16}
              height={16}
              fill={entry.saved ? "currentColor" : "none"}
            />
          </IconButton>
          <IconButton
            onClick={handleRetranscribe}
            disabled={busy}
            title={t("settings.history.retranscribe")}
          >
            <RotateCcw
              width={16}
              height={16}
              style={
                retrying
                  ? { animation: "spin 1s linear infinite reverse" }
                  : undefined
              }
            />
          </IconButton>
          <IconButton
            onClick={handleDeleteEntry}
            disabled={busy}
            title={t("settings.history.delete")}
          >
            <Trash2 width={16} height={16} />
          </IconButton>
        </div>
      </div>

      {editing ? (
        <div className="flex flex-col gap-2">
          <textarea
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            onKeyDown={handleDraftKeyDown}
            autoFocus
            rows={Math.min(8, Math.max(2, Math.ceil(draft.length / 70)))}
            className="w-full px-3 py-2 text-sm bg-mid-gray/10 border border-mid-gray/30 rounded-md resize-y focus:outline-none focus:border-logo-primary"
            aria-label={t("settings.history.correction.edit")}
          />
          <div className="flex items-center justify-between gap-2">
            <p className="text-xs text-text/50">
              {t("settings.history.correction.hint")}
            </p>
            <div className="flex gap-2 shrink-0">
              <Button
                variant="secondary"
                size="sm"
                onClick={() => setDraft(null)}
                disabled={savingCorrection}
              >
                {t("settings.history.correction.cancel")}
              </Button>
              <Button
                variant="primary"
                size="sm"
                onClick={handleSaveCorrection}
                disabled={savingCorrection}
              >
                {t("settings.history.correction.save")}
              </Button>
            </div>
          </div>
        </div>
      ) : (
        <p
          className={`italic text-sm pb-2 ${
            retrying
              ? ""
              : hasTranscription
                ? "text-text/90 select-text cursor-text whitespace-pre-wrap break-words"
                : "text-text/40"
          }`}
          style={
            retrying
              ? { animation: "transcribe-pulse 3s ease-in-out infinite" }
              : undefined
          }
        >
          {retrying && (
            <style>{`
              @keyframes transcribe-pulse {
                0%, 100% { color: color-mix(in srgb, var(--color-text) 40%, transparent); }
                50% { color: color-mix(in srgb, var(--color-text) 90%, transparent); }
              }
            `}</style>
          )}
          {retrying
            ? t("settings.history.transcribing")
            : hasTranscription
              ? displayText
              : t("settings.history.transcriptionFailed")}
        </p>
      )}

      <AudioPlayer onLoadRequest={handleLoadAudio} className="w-full" />
    </div>
  );
};
