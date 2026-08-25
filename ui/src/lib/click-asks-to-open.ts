import type { MouseEvent } from "react";

/** What answers a click before the surface may: any real control, plus a
 *  tooltip popup, which counts wherever the browser draws it because React
 *  sends its clicks back through the surface that owns it. */
const CONTROLS =
  'a, button, input, select, textarea, [role="button"], [data-slot="tooltip-content"]';

/**
 * Whether a click on a whole-surface shortcut — a project card, a Library
 * row, a marketplace row — is asking to open it. False when a control
 * inside the surface already answered the click, and false when the click
 * ended a text selection: a drag across the name was someone keeping the
 * text, not asking to leave the page. One predicate for every such surface,
 * so the guards cannot drift apart.
 */
export function clickAsksToOpen(event: MouseEvent<HTMLElement>): boolean {
  if ((event.target as HTMLElement).closest(CONTROLS)) return false;
  return !clickEndedSelection(event);
}

/**
 * Whether the click that just landed ended a text selection. Keyboard and
 * assistive activation arrive as clicks too, with detail 0, and they leave
 * any standing selection untouched — those always ask to open; only a
 * mouse click that left an uncollapsed selection is someone keeping the
 * text. A control inside the surface needs this half of the guard on its
 * own: its click is always its answer, but it fires before the surface's
 * guard can decline.
 */
export function clickEndedSelection(event: MouseEvent<HTMLElement>): boolean {
  if (event.detail === 0) return false;
  return window.getSelection()?.isCollapsed === false;
}
