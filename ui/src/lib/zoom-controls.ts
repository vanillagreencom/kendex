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
 * every few tens of milliseconds, and a button can be clicked nearly as
 * fast, so this has to sit well past a repeat interval — see the bound the
 * test holds it to.
 */
export const ZOOM_SETTLE_MS = 300;

/**
 * The zoom controls, wired to whatever changes and stores the size.
 *
 * Every input here comes in steps, and can come fast: a held `Ctrl` `+`, a
 * repeatedly clicked button. The window follows every step so the control
 * feels live, and the size is written once the steps stop — one settle for
 * every input, so no path rewrites the settings file per press.
 */
export interface ZoomControls {
  /** Whether the press was a zoom press, so the caller can keep it from
   *  the page. */
  onKeyDown: (event: ZoomShortcutEvent) => boolean;
  /** One press of the zoom-out or zoom-in button, `by` being the step and
   *  its sign the direction. */
  step: (by: number) => void;
  /** Start a pending write now instead of waiting out the settle: for a
   *  page going away, where the timer would never fire.
   *
   *  Best-effort, not a guarantee. The write is IPC behind a promise chain,
   *  so on a window close the runtime can end before the request is even
   *  sent — measured: dispatching `beforeunload` puts nothing on the wire
   *  in that turn, nor after its microtasks. It lands where the runtime
   *  outlives the unload, which a reload or a navigation does and a close
   *  may not. A size chosen in the last moments before quitting can still
   *  be lost; see the ARCHITECTURE bullet for why the close is not held
   *  open to prevent that. */
  flush: () => void;
}

export function zoomControls(actions: {
  /** The size on screen right now, or null before the settings that hold it
   *  have loaded. Read at the moment of the press, never handed in by the
   *  caller: a button reading a rendered prop loses a click whenever two
   *  land inside one render. */
  current: () => number | null;
  preview: (percent: number) => void;
  save: () => void;
}): ZoomControls {
  const { current, preview, save } = actions;
  let settle: ReturnType<typeof setTimeout> | undefined;
  const change = (next: number) => {
    preview(next);
    clearTimeout(settle);
    settle = setTimeout(() => {
      settle = undefined;
      save();
    }, ZOOM_SETTLE_MS);
  };
  return {
    onKeyDown(event) {
      // Not ours to swallow while the size is unknown: consuming the key
      // and arming the timer would make the press look taken when nothing
      // can act on it, and the size it would compute from is a guess.
      const now = current();
      if (now === null) return false;
      const next = zoomForKey(event, now);
      if (next === null) return false;
      change(next);
      return true;
    },
    step(by) {
      const now = current();
      if (now === null) return;
      change(clamp(now + by));
    },
    flush() {
      if (settle === undefined) return;
      clearTimeout(settle);
      settle = undefined;
      save();
    },
  };
}
