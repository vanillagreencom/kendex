import type { KeyboardEvent, MouseEvent } from "react";
import { clickAsksToOpen } from "@/lib/click-asks-to-open";

/** The props a whole surface — a table row, a card, a list line — takes to
 *  become the way into the thing it names. */
export interface OpensOnActivate {
  /** The surface joins the tab order after the controls before it and
   *  before the ones inside it, so a keyboard reaches the row itself. */
  tabIndex: 0;
  /** What the surface is, said in words, because a focus stop that
   *  announces only the cells it holds does not tell anyone that landing
   *  on it and pressing Enter goes anywhere. */
  "aria-label": string;
  /** The key that opens it, so the announcement carries the how as well as
   *  the what. */
  "aria-keyshortcuts": "Enter";
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
 * replacement for it: the name stays a real button, and this puts the whole
 * surface behind the same action for everyone else.
 *
 * It takes no widget role. A `role="button"` holding real buttons is
 * invalid, and on a table row it would replace the row semantics a screen
 * reader navigates a table by. What the extra stop needs instead is to say
 * what it is and what opens it, which is `label` plus the Enter shortcut —
 * so the reader who lands on it is told "Open gh, Enter" rather than
 * hearing a row's cells read out with no action named.
 */
export function opensOnActivate(
  onOpen: () => void,
  /** What this surface opens, as a person would say it: "Open gh". */
  label: string,
): OpensOnActivate {
  return {
    tabIndex: 0,
    "aria-label": label,
    "aria-keyshortcuts": "Enter",
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

/** What a whole-surface shortcut announces: the one phrase every row, card
 *  and line uses, so the same affordance never says two different things.
 *  It names the thing, not the surface — a reader landing on it wants to
 *  know where Enter goes, not what shape the shortcut is. */
export const opensLabel = (thing: string): string => `Open ${thing}`;
