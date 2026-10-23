import React from "react";
import { useTranslation } from "react-i18next";
import type { OverlayPosition } from "@/bindings";

// Row-major 3×3 grid, matching the screen: top row first, left to right.
const POSITIONS: OverlayPosition[] = [
  "top_left",
  "top_center",
  "top_right",
  "center_left",
  "center",
  "center_right",
  "bottom_left",
  "bottom_center",
  "bottom_right",
];

// Where the little indicator sits inside its cell, so the grid reads as a
// thumbnail of the screen.
const CELL_ALIGN: Record<OverlayPosition, string> = {
  top_left: "items-start justify-start",
  top_center: "items-start justify-center",
  top_right: "items-start justify-end",
  center_left: "items-center justify-start",
  center: "items-center justify-center",
  center_right: "items-center justify-end",
  bottom_left: "items-end justify-start",
  bottom_center: "items-end justify-center",
  bottom_right: "items-end justify-end",
};

interface OverlayPositionPickerProps {
  value: OverlayPosition;
  onChange: (position: OverlayPosition) => void;
  disabled?: boolean;
}

/** A screen thumbnail with one target per grid cell. */
export const OverlayPositionPicker: React.FC<OverlayPositionPickerProps> = ({
  value,
  onChange,
  disabled = false,
}) => {
  const { t } = useTranslation();

  return (
    <div
      role="radiogroup"
      aria-label={t("settings.advanced.overlay.position.title")}
      className="grid grid-cols-3 gap-0.5 w-32 p-1 rounded-md border border-mid-gray/30 bg-mid-gray/5"
    >
      {POSITIONS.map((position) => {
        const selected = position === value;
        const label = t(
          `settings.advanced.overlay.position.options.${position}`,
        );
        return (
          <button
            key={position}
            type="button"
            role="radio"
            aria-checked={selected}
            aria-label={label}
            title={label}
            disabled={disabled}
            onClick={() => onChange(position)}
            className={`flex h-7 p-1 rounded cursor-pointer transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-logo-primary/60 disabled:cursor-not-allowed disabled:opacity-50 ${CELL_ALIGN[position]} ${
              selected ? "bg-logo-primary/15" : "hover:bg-mid-gray/15"
            }`}
          >
            <span
              className={`h-1.5 w-4 rounded-full transition-colors ${
                selected ? "bg-logo-primary" : "bg-mid-gray/40"
              }`}
            />
          </button>
        );
      })}
    </div>
  );
};
