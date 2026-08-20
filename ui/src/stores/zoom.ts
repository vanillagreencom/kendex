import { ZOOM } from "@/bindings";
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
/**
 * The size on screen, or null while the settings that hold it are still
 * loading. Settings that arrived without an explicit size are a different
 * answer: that means the default, not "unknown".
 */
export function currentZoom(): number | null {
  const settings = useSettingsStore.getState().settings;
  return settings ? (settings.zoom ?? ZOOM.default) : null;
}

export const zoom = zoomControls({
  current: currentZoom,
  preview: (percent) => void useSettingsStore.getState().setZoom(percent),
  save: () => void useSettingsStore.getState().saveZoom(),
});
