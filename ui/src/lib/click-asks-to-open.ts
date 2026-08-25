import type { MouseEvent } from "react";

/**
 * Whether a click on a whole-surface shortcut — a project card, a Library
 * row — is asking to open it. False when a control inside the surface
 * already answered the click, and false when the click ended a text
 * selection: a drag across the name was someone keeping the text, not
 * asking to leave the page. One predicate for every such surface, so the
 * two guards cannot drift apart.
 */
export function clickAsksToOpen(event: MouseEvent<HTMLElement>): boolean {
  if ((event.target as HTMLElement).closest("button")) return false;
  if (window.getSelection()?.isCollapsed === false) return false;
  return true;
}
