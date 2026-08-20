import { ZOOM } from "@/bindings";

// Plain-shape event so this stays testable without a DOM: a real
// KeyboardEvent structurally satisfies it at the call site.
export interface ZoomShortcutEvent {
  key: string;
  ctrlKey: boolean;
  metaKey: boolean;
  altKey: boolean;
}

function clamp(percent: number): number {
  return Math.min(ZOOM.max, Math.max(ZOOM.min, percent));
}

/**
 * The zoom a keypress asks for, or null when the press means something else.
 * Ctrl and Cmd both count, the way they do in a browser: `+` zooms in, `-`
 * out, `0` back to full size. Alt is excluded because Alt combinations
 * belong to the window manager; Shift is not looked at, since `+` is a
 * shifted key on most layouts.
 */
export function zoomForKey(
  event: ZoomShortcutEvent,
  current: number,
): number | null {
  if (!(event.ctrlKey || event.metaKey) || event.altKey) return null;
  switch (event.key) {
    case "+":
    case "=":
      return clamp(current + ZOOM.step);
    case "-":
    case "_":
      return clamp(current - ZOOM.step);
    case "0":
      return ZOOM.default;
    default:
      return null;
  }
}

/**
 * How long after the last press the size is written. A held key repeats
 * every few tens of milliseconds, so this sits comfortably past a repeat
 * without making a single press feel unsaved.
 */
export const ZOOM_SETTLE_MS = 300;

/**
 * A zoom gesture on the keyboard, the counterpart to a slider drag: the
 * window follows every press, and the size is written once the presses
 * stop. Holding the key would otherwise rewrite the settings file at the
 * keyboard's repeat rate for one gesture.
 *
 * Returns whether the press was a zoom press, so the caller knows whether
 * to keep it from the page.
 */
export function zoomGesture(
  preview: (percent: number) => void,
  save: () => void,
): (event: ZoomShortcutEvent, current: number) => boolean {
  let settle: ReturnType<typeof setTimeout> | undefined;
  return (event, current) => {
    const next = zoomForKey(event, current);
    if (next === null) return false;
    preview(next);
    clearTimeout(settle);
    settle = setTimeout(save, ZOOM_SETTLE_MS);
    return true;
  };
}
