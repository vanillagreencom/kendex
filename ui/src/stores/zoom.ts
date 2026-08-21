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
 * The size on screen, or null while the app is still loading — settings
 * that have not arrived, which is not the same answer as settings that
 * arrived carrying no size.
 *
 * The store owns what "on screen" means: a press the window has not
 * answered for, and a launch the window would not take the stored size at,
 * both move it away from what the settings file says. So this asks rather
 * than working it out a second way.
 */
export function currentZoom(): number | null {
  const { settings, onScreen } = useSettingsStore.getState();
  return settings ? onScreen() : null;
}

export const zoom = zoomControls({
  current: currentZoom,
  preview: (percent) => void useSettingsStore.getState().setZoom(percent),
  save: () => void useSettingsStore.getState().saveZoom(),
});
