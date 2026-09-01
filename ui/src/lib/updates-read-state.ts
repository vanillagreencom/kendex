import type { Scope } from "@/bindings";
import type { ReadState } from "@/lib/read-state";
import { sameScope } from "@/lib/scope";

/** What every predicate here reads: how the last read of the standing went,
 *  and whether one that will replace it is on its way — an explicit check,
 *  or an ordinary reload from a mount or a return to the window. */
interface PageState {
  read: ReadState;
  checking: boolean;
  reading: boolean;
}

/** Whether the rows on screen are not to be acted on, page-wide: the first
 *  read has not answered, the last one failed, or one that will replace
 *  every row is on its way. A landed read is not enough on its own — a
 *  mount or a return to the window starts a reload over rows that landed
 *  perfectly well, and the answer it brings back is what the captured
 *  values would be committed against. A settling follow flip is not here:
 *  it replaces every row too, but which rows it leaves unconfirmed is its
 *  own scope's, so ask `rowUnsettled` about a given row. The page-wide
 *  hold a flip's write takes is the store's `busy`, which nothing here
 *  reads. */
export const unsettled = (state: PageState): boolean =>
  state.read.status !== "landed" || state.checking || state.reading;

/** Whether a Follow source flip is settling in this row's own place. The
 *  apply behind it moves what is installed in that scope and nowhere
 *  else, so a second write there would contend for that scope's writer
 *  lock.
 *
 *  Asked on its own by a surface that wants this and not the rest of
 *  [`unsettled`]: the page's Update carries no argument read off the row,
 *  so a read in flight cannot stale it — a flip in the same place is what
 *  still speaks against it. */
export const settlingIn = (
  state: { pendingFollows: { scope: Scope }[] },
  row: { scope: Scope },
): boolean =>
  state.pendingFollows.some((one) => sameScope(one.scope, row.scope));

/** Whether one row's facts are not to be acted on: everything `unsettled`
 *  answers for the page, and a follow switch still settling in that row's
 *  scope. For the surface whose actions capture values off the row — the
 *  Updates table sends `row.latest.commit` — so rows about to be replaced
 *  are rows whose values must not be committed. */
export const rowUnsettled = (
  state: PageState & { pendingFollows: { scope: Scope }[] },
  row: { scope: Scope },
): boolean => unsettled(state) || settlingIn(state, row);
