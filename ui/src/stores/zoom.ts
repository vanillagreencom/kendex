import { zoomControls } from "@/lib/zoom-controls";
import { useSettingsStore } from "./settings";

/**
 * The app's zoom controls — one instance, so the keyboard and the slider
 * share a settle instead of each keeping its own and writing the settings
 * file twice for one gesture.
 *
 * It reads the actions off the store when a key is pressed rather than
 * holding them, so it needs no React lifetime and both consumers can simply
 * import it.
 */
export const zoom = zoomControls(
  (percent) => void useSettingsStore.getState().setZoom(percent),
  () => void useSettingsStore.getState().saveZoom(),
);
