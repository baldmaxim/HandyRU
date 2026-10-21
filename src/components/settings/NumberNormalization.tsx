import React from "react";
import { useTranslation } from "react-i18next";
import { ToggleSwitch } from "../ui/ToggleSwitch";
import { useSettings } from "../../hooks/useSettings";

interface NumberNormalizationProps {
  descriptionMode?: "inline" | "tooltip";
  grouped?: boolean;
}

export const NumberNormalization: React.FC<NumberNormalizationProps> =
  React.memo(({ descriptionMode = "tooltip", grouped = false }) => {
    const { t } = useTranslation();
    const { getSetting, updateSetting, isUpdating } = useSettings();
    const enabled = getSetting("number_normalization_enabled") ?? true;

    return (
      <ToggleSwitch
        checked={enabled}
        onChange={(nextEnabled) =>
          updateSetting("number_normalization_enabled", nextEnabled)
        }
        isUpdating={isUpdating("number_normalization_enabled")}
        label={t("settings.advanced.numberNormalization.title")}
        description={t("settings.advanced.numberNormalization.description")}
        descriptionMode={descriptionMode}
        grouped={grouped}
      />
    );
  });
