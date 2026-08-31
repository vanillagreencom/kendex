import type { Scope } from "@/bindings";
import { sameScope } from "@/lib/scope";

/** What every predicate here reads: how the last read of the standing went,
 *  and whether one that would replace it is running. */
interface PageState {
  loaded: boolean;
  checking: boolean;
  overviewInFlight: boolean;
}

/** How the read of the update standing stands. Three answers that must
 *  never blur: a first read still on its way, a read that failed, and a
 *  read that landed. Only the last may say "nothing here". A failed
 *  re-read keeps the rows it had, but `loaded` drops with it, so those
 *  rows are last-known rather than facts and the state is `failed`. */
export type UpdatesReadState = "pending" | "landed" | "failed";

export function updatesReadState(state: {
  loaded: boolean;
  error: string | null;
}): UpdatesReadState {
  if (state.error !== null) return "failed";
  return state.loaded ? "landed" : "pending";
}

/** Whether the rows on screen are not to be acted on, page-wide: the first
 *  read has not answered or the last one failed, a check is running, or an
 *  operation that replaces every row is in flight. A settling follow flip
 *  is not here — it replaces every row too but holds only its own scope, so
 *  ask `rowUnsettled` whether a given row may be acted on. */
export const unsettled = (state: PageState): boolean =>
  !state.loaded || state.checking || state.overviewInFlight;

/** Whether a write is already running in this row's own place. The apply
 *  behind a Follow source flip moves what is installed in that scope and
 *  nowhere else, so a second write there would contend for the same
 *  writer lock while every other row stays live.
 *
 *  Asked on its own by a surface that wants this and not the rest of
 *  [`unsettled`]: the page's Update carries no argument read off the row,
 *  so a read in flight cannot stale it — only a write in the same place
 *  bars it. */
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
