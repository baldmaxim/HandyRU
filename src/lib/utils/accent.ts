import { commands } from "@/bindings";

/**
 * Accent color handling.
 *
 * The preset id is set as `data-accent` on the document root; the matching
 * palette overrides live in `styles/theme.css`. Like the theme, the choice is
 * persisted in `AppSettings` (source of truth) and mirrored to localStorage so
 * it can be applied synchronously on boot, before React mounts.
 */

export const ACCENT_STORAGE_KEY = "handy.accent";

export const ACCENT_OPTIONS = [
  "blue",
  "green",
  "violet",
  "orange",
  "graphite",
  "pink",
] as const;

export type Accent = (typeof ACCENT_OPTIONS)[number];

export const DEFAULT_ACCENT: Accent = "blue";

/** Swatch colors for the picker; mirror the light-theme presets in theme.css. */
export const ACCENT_SWATCHES: Record<Accent, string> = {
  blue: "#3b82f6",
  green: "#16a34a",
  violet: "#8b5cf6",
  orange: "#f97316",
  graphite: "#52525b",
  pink: "#faa2ca",
};

export const isAccent = (value: unknown): value is Accent =>
  typeof value === "string" &&
  (ACCENT_OPTIONS as readonly string[]).includes(value);

/** Apply an accent to the document root and remember it for the next launch. */
export const applyAccent = (accent: string): void => {
  const value = isAccent(accent) ? accent : DEFAULT_ACCENT;
  document.documentElement.dataset.accent = value;
  try {
    localStorage.setItem(ACCENT_STORAGE_KEY, value);
  } catch {
    // localStorage may be unavailable (e.g. private mode); the setting still
    // persists in AppSettings, so this only costs a one-frame flash on boot.
  }
};

/** Read the last-applied accent for synchronous boot-time application. */
export const getStoredAccent = (): Accent => {
  try {
    const stored = localStorage.getItem(ACCENT_STORAGE_KEY);
    if (isAccent(stored)) return stored;
  } catch {
    // ignore
  }
  return DEFAULT_ACCENT;
};

/** Apply the persisted accent from AppSettings (the source of truth). */
export const syncAccentFromSettings = async (): Promise<void> => {
  try {
    const result = await commands.getAppSettings();
    if (result.status === "ok") {
      applyAccent(result.data.accent_color ?? DEFAULT_ACCENT);
    }
  } catch (e) {
    console.warn("Failed to sync accent from settings:", e);
  }
};
