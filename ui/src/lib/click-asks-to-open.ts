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
 * ended a text selection: a drag across the surface's text was someone
 * keeping the text, not asking to leave the page. Keyboard and assistive
 * activation arrive as clicks with detail 0 and leave any standing
 * selection untouched, so they always ask. One predicate for every such
 * surface, so the guards cannot drift apart.
 *
 * Surfaces only, never a control inside one: a completed click on a real
 * button — mousedown and mouseup both on it — is unambiguous intent to
 * activate, and guarding it turns a standing selection elsewhere into a
 * dead click on WebKit, where a button click leaves the selection be.
 */
export function clickAsksToOpen(event: MouseEvent<HTMLElement>): boolean {
  if ((event.target as HTMLElement).closest(CONTROLS)) return false;
  if (event.detail === 0) return true;
  return window.getSelection()?.isCollapsed !== false;
}
