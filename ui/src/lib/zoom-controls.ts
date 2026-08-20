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
 * How long after the last input the size is written. A held key repeats
 * every few tens of milliseconds and a slider under an arrow key commits
 * once per repeat, so this has to sit well past a repeat interval — see the
 * bound the test holds it to.
 */
export const ZOOM_SETTLE_MS = 300;

/**
 * The zoom controls, wired to whatever changes and stores the size.
 *
 * Every input here is a stream: a drag, a held `Ctrl` `+`, an arrow key on
 * the focused slider. The window follows all of them so the control feels
 * live, and the size is written once the stream stops — one settle for
 * every input, so no path rewrites the settings file per keypress.
 */
export interface ZoomControls {
  /** Whether the press was a zoom press, so the caller can keep it from
   *  the page. */
  onKeyDown: (event: ZoomShortcutEvent, current: number) => boolean;
  /** Spread onto the slider. One object rather than two props, so half of
   *  the wiring cannot go missing: without it the slider moves nothing at
   *  all, which is seen the moment anyone drags it. */
  slider: {
    onValueChange: (percent: number) => void;
    onValueCommitted: () => void;
  };
  /** Write a pending size now rather than waiting out the settle — for the
   *  app going away, which is the one moment the timer would never fire. */
  flush: () => void;
}

export function zoomControls(
  preview: (percent: number) => void,
  save: () => void,
): ZoomControls {
  let settle: ReturnType<typeof setTimeout> | undefined;
  const commitWhenSettled = () => {
    clearTimeout(settle);
    settle = setTimeout(() => {
      settle = undefined;
      save();
    }, ZOOM_SETTLE_MS);
  };
  return {
    onKeyDown(event, current) {
      const next = zoomForKey(event, current);
      if (next === null) return false;
      preview(next);
      commitWhenSettled();
      return true;
    },
    slider: { onValueChange: preview, onValueCommitted: commitWhenSettled },
    flush() {
      if (settle === undefined) return;
      clearTimeout(settle);
      settle = undefined;
      save();
    },
  };
}
