// How the last read of a store's standing went, in the one shape every
// store that has one uses.
//
// Three answers that must never blur: a first read still on its way, a read
// that failed, and a read that landed. Only the last may say "nothing
// here". A failed re-read keeps the rows it had, so those rows are
// last-known rather than facts, and `error` is why nothing confirmed them.

export type ReadStatus = "pending" | "landed" | "failed";

export interface ReadState {
  status: ReadStatus;
  /** Why the last read failed, or null. Written only by the read, never by
   *  an action, so a failed write never rewrites the reason a surface gives
   *  for showing rows it could not refresh. */
  error: string | null;
}

/** No read has answered yet. */
export const READ_PENDING: ReadState = { status: "pending", error: null };

/** The rows on screen are the last read's answer. */
export const READ_LANDED: ReadState = { status: "landed", error: null };

export const readFailed = (error: string): ReadState => ({
  status: "failed",
  error,
});

/** What a settled command answer leaves behind. */
export const readOf = (
  response: { status: "ok" } | { status: "error"; error: string },
): ReadState =>
  response.status === "ok" ? READ_LANDED : readFailed(response.error);

/** Orders the landings of overlapping reads of one standing, so the newest
 *  answer is the one on screen.
 *
 *  Reads of the same thing overlap on every ordinary path: the app's startup
 *  effect against the page's own mount, the focus rescan against whatever is
 *  already out, a mutation's re-read behind both. Of two answers the
 *  later-begun read saw the newer state, so only the newest-begun read may
 *  write. An older one says nothing even when it answers first, because a
 *  read known to be superseded has nothing to add and its landing would
 *  flicker the wrong state onto the page on its way past.
 *
 *  The whole [ReadState] rides on this, not just the rows: an older landing
 *  overwriting a newer failure clears the banner that says the rows are
 *  unconfirmed, and every predicate reading `status` re-enables the writes
 *  that banner exists to hold back.
 *
 *  An answer a side-effect produced ranks by when it LANDS instead — it
 *  reports the state its own work made, newer than anything still in flight.
 *  Spell that `order.lands(order.begin())` at the landing itself, which also
 *  supersedes every read still out.
 *
 *  A ticket answers the same way however often it is asked, so there is no
 *  once-only rule to break: each caller takes one as its read begins and
 *  asks once when that read answers.
 *
 *  `outstanding` is the same fact read the other way — a ticket taken and
 *  not yet landed is a read still on its way, which is what tells a page
 *  that the rows under its buttons are about to be replaced. It is the
 *  ordering rule answering that question rather than a second flag counted
 *  beside it, so the two cannot disagree. */
export function readOrder(): {
  begin: () => number;
  lands: (ticket: number) => boolean;
  outstanding: () => boolean;
} {
  let begun = 0;
  let landed = 0;
  return {
    begin: () => ++begun,
    lands: (ticket) => {
      if (ticket !== begun) return false;
      landed = ticket;
      return true;
    },
    outstanding: () => begun !== landed,
  };
}

/** What a read may no longer answer for. Where [readOrder] asks which of two
 *  reads is newer, this asks whether what a read was about still exists: a
 *  cache emptied because a mutation moved every catalog, a credential that
 *  changed hands. A read that began before the change describes a state that
 *  is gone, however new its answer is.
 *
 *  Keyed caches need this and not the ordering: two reads under different
 *  keys are not competing answers, and ranking them would drop the second
 *  key's. */
export function invalidations(): {
  moved: () => void;
  since: () => number;
  stale: (at: number) => boolean;
} {
  let at = 0;
  return {
    moved: () => {
      at += 1;
    },
    since: () => at,
    stale: (began) => began !== at,
  };
}
