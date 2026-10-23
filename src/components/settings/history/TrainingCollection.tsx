import React, { useCallback, useEffect, useState } from "react";
import { useTranslation } from "react-i18next";
import { commands, events, type TrainingStats } from "@/bindings";
import { useSettings } from "../../../hooks/useSettings";
import { SettingsGroup } from "../../ui/SettingsGroup";
import { ToggleSwitch } from "../../ui/ToggleSwitch";

/** Toggle for keeping every dictation as voice-model material, with totals. */
export const TrainingCollection: React.FC = () => {
  const { t } = useTranslation();
  const { getSetting, updateSetting, isUpdating } = useSettings();
  const [stats, setStats] = useState<TrainingStats | null>(null);

  const enabled = getSetting("training_collection_enabled") ?? true;

  const refresh = useCallback(async () => {
    try {
      const result = await commands.getTrainingStats();
      if (result.status === "ok") setStats(result.data);
    } catch (error) {
      console.error("Failed to load training stats:", error);
    }
  }, []);

  useEffect(() => {
    refresh();
    // Re-count whenever a dictation is added, corrected or deleted.
    const unlisten = events.historyUpdatePayload.listen(() => refresh());
    return () => {
      unlisten.then((fn) => fn());
    };
  }, [refresh]);

  const formatDuration = (seconds: number) => {
    const totalMinutes = Math.round(seconds / 60);
    const hours = Math.floor(totalMinutes / 60);
    const minutes = totalMinutes % 60;
    return hours > 0
      ? t("settings.history.training.hoursMinutes", { hours, minutes })
      : t("settings.history.training.minutes", { minutes });
  };

  return (
    <SettingsGroup title={t("settings.history.training.title")}>
      <ToggleSwitch
        checked={enabled}
        onChange={(value) =>
          updateSetting("training_collection_enabled", value)
        }
        isUpdating={isUpdating("training_collection_enabled")}
        label={t("settings.history.training.label")}
        description={t("settings.history.training.description")}
        descriptionMode="tooltip"
        grouped={true}
      />
      {stats && (
        <p className="px-4 py-3 text-sm text-text/70 tabular-nums">
          {t("settings.history.training.stats", {
            total: formatDuration(stats.total_seconds),
            entries: stats.entries,
            corrected: stats.corrected,
            correctedTotal: formatDuration(stats.corrected_seconds),
          })}
        </p>
      )}
    </SettingsGroup>
  );
};
