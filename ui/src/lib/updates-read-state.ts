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

/** Whether the rows on screen are not to be acted on: the first read has
 *  not answered or the last one failed, a check is running, or anything
 *  overview-producing is in flight and about to replace them. One
 *  predicate for every control that holds and every action that refuses. */
export const unsettled = (state: PageState): boolean =>
  !state.loaded || state.checking || state.overviewInFlight;

/** Whether one row's facts are not to be acted on: everything `unsettled`
 *  answers for the page, and a follow switch still settling in that row's
 *  scope. The apply behind a flip moves what is installed in that scope and
 *  nowhere else, so every other row stays live while it runs. */
export const rowUnsettled = (
  state: PageState & { pendingFollows: { scope: Scope }[] },
  row: { scope: Scope },
): boolean =>
  unsettled(state) ||
  state.pendingFollows.some((one) => sameScope(one.scope, row.scope));

/** `unsettled` for an action that spans every scope — "Update all" acts on
 *  rows wherever they live, so any settling flip is one of them. */
export const anyUnsettled = (
  state: PageState & { pendingFollows: unknown[] },
): boolean => unsettled(state) || state.pendingFollows.length > 0;
