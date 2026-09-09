import type { KeyboardEvent, MouseEvent } from "react";
import { clickAsksToOpen } from "@/lib/click-asks-to-open";

/** The props a whole surface — a table row, a card, a list line — takes to
 *  become the way into the thing it names. */
export interface OpensOnActivate {
  /** The surface joins the tab order after the controls before it and
   *  before the ones inside it, so a keyboard reaches the row itself. */
  tabIndex: 0;
  onClick: (event: MouseEvent<HTMLElement>) => void;
  onKeyDown: (event: KeyboardEvent<HTMLElement>) => void;
}

/**
 * One convention, everywhere: a row, card or chip that names a thing opens
 * that thing. Spread onto the surface, this makes a click on it open —
 * unless a control inside already answered, or the click ended a drag over
 * its text, which `clickAsksToOpen` settles — and puts the same open on
 * Enter for a keyboard.
 *
 * Enter only, and only on the surface itself. Space scrolls the page, and
 * taking it from a row that fills the screen would strand a keyboard on a
 * long list; a key pressed on a button inside the surface belongs to that
 * button, which runs its own handler and must not open the row as well.
 *
 * The surface is a shortcut on top of the name's own control, never a
 * replacement for it: the name stays a real button so a screen reader is
 * told what opens, and this puts the whole surface behind the same action
 * for everyone else.
 */
export function opensOnActivate(onOpen: () => void): OpensOnActivate {
  return {
    tabIndex: 0,
    onClick: (event) => {
      if (clickAsksToOpen(event)) onOpen();
    },
    onKeyDown: (event) => {
      if (event.key !== "Enter") return;
      if (event.defaultPrevented) return;
      if (event.target !== event.currentTarget) return;
      // The surface is not a button, so the browser does nothing with
      // Enter here — but a row inside a form or a dialog would submit it.
      event.preventDefault();
      onOpen();
    },
  };
}
