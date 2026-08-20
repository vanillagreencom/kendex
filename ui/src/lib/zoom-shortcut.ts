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
