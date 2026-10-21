import React from "react";
import { useTranslation } from "react-i18next";
import { SettingContainer } from "../ui/SettingContainer";
import { useSettings } from "@/hooks/useSettings";
import {
  ACCENT_OPTIONS,
  ACCENT_SWATCHES,
  applyAccent,
  DEFAULT_ACCENT,
  isAccent,
} from "@/lib/utils/accent";

interface AccentColorSelectorProps {
  descriptionMode?: "inline" | "tooltip";
  grouped?: boolean;
}

export const AccentColorSelector: React.FC<AccentColorSelectorProps> =
  React.memo(({ descriptionMode = "tooltip", grouped = false }) => {
    const { t } = useTranslation();
    const { settings, updateSetting } = useSettings();

    const stored = settings?.accent_color;
    const currentAccent = isAccent(stored) ? stored : DEFAULT_ACCENT;

    const handleAccentChange = (accent: string) => {
      applyAccent(accent);
      updateSetting("accent_color", accent);
    };

    return (
      <SettingContainer
        title={t("accent.title")}
        description={t("accent.description")}
        descriptionMode={descriptionMode}
        grouped={grouped}
      >
        <div className="flex items-center gap-2" role="radiogroup">
          {ACCENT_OPTIONS.map((value) => {
            const selected = value === currentAccent;
            return (
              <button
                key={value}
                type="button"
                role="radio"
                aria-checked={selected}
                aria-label={t(`accent.options.${value}`)}
                title={t(`accent.options.${value}`)}
                onClick={() => handleAccentChange(value)}
                style={{ backgroundColor: ACCENT_SWATCHES[value] }}
                className={`h-6 w-6 rounded-full cursor-pointer transition-shadow focus:outline-none focus-visible:ring-2 focus-visible:ring-text/60 ${
                  selected
                    ? "ring-2 ring-text ring-offset-2 ring-offset-background"
                    : "hover:ring-2 hover:ring-mid-gray/50"
                }`}
              />
            );
          })}
        </div>
      </SettingContainer>
    );
  });

AccentColorSelector.displayName = "AccentColorSelector";
