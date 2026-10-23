import { create } from "zustand";

// idle → (check finds an update) → downloading → ready → installing.
// Portable installs stop at "available": they can't self-update in place.
export type UpdateStage =
  | "idle"
  | "available"
  | "downloading"
  | "ready"
  | "installing";

interface IUpdateStore {
  /** Update checks allowed by the setting and not locked by the system. */
  enabled: boolean;
  stage: UpdateStage;
  /** Version of the update being fetched or ready to install. */
  version: string;
  /** Download progress, 0–100. */
  progress: number;
  isChecking: boolean;
  /** Briefly true after a manual check found nothing new. */
  showUpToDate: boolean;
  /** Check right now, regardless of the periodic schedule. */
  checkNow: () => void;
  /** Install the downloaded update, or show the portable-install dialog. */
  install: () => void;
}

/**
 * Update status shared by every place that shows it (footer, About page). The
 * single UpdateChecker instance owns the logic and registers the actions.
 */
export const useUpdateStore = create<IUpdateStore>(() => ({
  enabled: false,
  stage: "idle",
  version: "",
  progress: 0,
  isChecking: false,
  showUpToDate: false,
  checkNow: () => {},
  install: () => {},
}));
