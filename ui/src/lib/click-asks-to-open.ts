import type { MouseEvent } from "react";

/** What answers a click before the surface may: any real control, plus a
 *  tooltip popup, a dropdown menu, or a dialog and its backdrop, which count
 *  wherever the browser draws them because React sends a portal's clicks back
 *  through the surface that owns it. A dialog opened from a card is read, not
 *  a request to leave the page; its backdrop is pressed to close it.
 *
 *  A tick box is matched by its role: `components/ui/checkbox.tsx` draws the
 *  box as a span, with its input hidden beside it, so a press on the box
 *  reaches no element selector here.
 *
 *  The menu is matched by the prefix its parts share rather than by their
 *  roles: a menu item renders as a plain div, so no element selector reaches
 *  it, and the popup's own padding lies between the items. One selector
 *  covers every part the wrapper draws, including any it grows. */
const CONTROLS =
  'a, button, input, select, textarea, [role="button"], [role="checkbox"], [data-slot="tooltip-content"], [data-slot="dialog-content"], [data-slot="dialog-overlay"], [data-slot^="dropdown-menu-"]';

/** Whether the point pressed lies over a control inside the surface that is
 *  switched off. A disabled control carries `pointer-events: none`, so the
 *  browser hands the click to the surface behind it and the walk up from the
 *  target never meets the button: pressing a greyed-out Update would open the
 *  package page. The answer has to come from the geometry, and from the
 *  element's own box rather than the point: `elementsFromPoint` honours
 *  `pointer-events: none` exactly as the click did, so it cannot see the
 *  control either. The box covers [left, right) and [top, bottom), so the
 *  line along its far edges belongs to what is drawn beyond it.
 *
 *  Only for a pressed point. Keyboard and assistive activation arrive with
 *  detail 0 and no meaningful coordinates, and a disabled control cannot hold
 *  focus, so there is nothing here for them to answer. */
function pressLandsOnDisabledControl(event: MouseEvent<HTMLElement>): boolean {
  for (const control of event.currentTarget.querySelectorAll(":disabled")) {
    const box = control.getBoundingClientRect();
    if (
      event.clientX >= box.left &&
      event.clientX < box.right &&
      event.clientY >= box.top &&
      event.clientY < box.bottom
    )
      return true;
  }
  return false;
}

/**
 * Whether a click on a whole-surface shortcut — a project card, a Library
 * row, a marketplace row — is asking to open it. False when a control
 * inside the surface already answered the click, false when the point
 * pressed lies over a control that is switched off, and false when the click
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
  if (pressLandsOnDisabledControl(event)) return false;
  return window.getSelection()?.isCollapsed !== false;
}
