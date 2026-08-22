import type { Scope } from "@/bindings";
import type { Draft } from "@/lib/editor-draft";
import { scopeKey } from "@/lib/scope";

// What parking is allowed to do.
//
// Parking keeps a copy nobody has ruled on. A move between places is not a
// ruling — the typing is still someone's, and still theirs to save — so it
// survives the move. Every operation that does rule on a place's draft
// outranks parking, and must reach the copy parked for that place and not
// only the one on screen: `dropHeld` for an instruction to destroy it,
// `settleHeld` for a write that landed on its file. The next operation that
// comes to rule on a draft owes the same — park what nobody has ruled on,
// never what someone has ruled against.

/** Typing waiting at the place it was read from, with the base it was read
 *  against — so a file rewritten while it waited still refuses its save,
 *  the same refusal it would have met without the wait. */
export interface HeldDraft {
  scope: Scope;
  draft: Draft;
  base: string | null;
}

/** Every place holding typing the editor is not showing, keyed by place. */
export type Held = Record<string, HeldDraft>;

/** The part of the editor a move between places rewrites. */
interface Pointed {
  scope: Scope;
  draft: Draft | null;
  base: string | null;
  dirty: boolean;
  held: Held;
}

/** Throw away the copy parked at a place: the person said to destroy it.
 *  Taken before the read that replaces it is awaited, so a move made in
 *  that window parks nothing and cannot bring the edits back. */
export function dropHeld(held: Held, scope: Scope): Held {
  const key = scopeKey(scope);
  if (!held[key]) return held;
  const next = { ...held };
  delete next[key];
  return next;
}

/** Settle the copy parked at a place against a write that just landed
 *  there. `saved` is the draft that went; `written` is what the file is
 *  now, or null when it could not be read back; `wroteMore` says the write
 *  put down something it was not sent. */
export function settleHeld(
  held: Held,
  scope: Scope,
  written: string | null,
  saved: Draft,
  wroteMore: boolean,
): Held {
  const key = scopeKey(scope);
  const waiting = held[key];
  if (!waiting) return held;
  const next = { ...held };
  // The parked copy is the one that was written: it is on disk now, so it
  // is not unsaved any more and opening its place reads the file.
  if (waiting.draft === saved) delete next[key];
  // Typing that arrived after the write left descends from it, so it takes
  // that file's base or its own save is refused for a change it made
  // itself. With no base to take, the caller marks the place instead.
  //
  // Unless the write put down something it was not sent — the seed a first
  // manifest gets, or a name derived for a hook. That copy never held it,
  // so it does not descend from this file, and handing it this base would
  // let its save write that away. It keeps the base it has, which the file
  // it does not match refuses on its own evidence.
  else if (written !== null && !wroteMore)
    next[key] = { ...waiting, base: written };
  else return held;
  return next;
}

/** Point the editor at another place.
 *
 *  A manifest belongs to one place, so the copy in hand belongs to the
 *  place it was read from and not to the one being opened. It waits there
 *  instead of being dropped, and whatever was already waiting at the place
 *  being opened comes back out. Crossing places is how the per-place marks
 *  are meant to be used — every mark is a link to another place — so the
 *  move itself must never cost someone what they typed. */
export function pointAt(state: Pointed, scope: Scope): Pointed {
  const held = { ...state.held };
  if (state.dirty && state.draft)
    held[scopeKey(state.scope)] = {
      scope: state.scope,
      draft: state.draft,
      base: state.base,
    };
  const waiting = held[scopeKey(scope)];
  // In hand and waiting would be the same copy counted twice, and the note
  // about typing left elsewhere would name the place on screen.
  delete held[scopeKey(scope)];
  return {
    scope,
    held,
    draft: waiting?.draft ?? null,
    base: waiting?.base ?? null,
    // Typing that comes back out is still unsaved: the Save bar stays up,
    // and the read that follows leaves it alone rather than reading over it.
    dirty: waiting !== undefined,
  };
}
