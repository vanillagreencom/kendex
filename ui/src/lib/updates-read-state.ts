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
export const unsettled = (state: {
  loaded: boolean;
  checking: boolean;
  overviewInFlight: boolean;
}): boolean => !state.loaded || state.checking || state.overviewInFlight;
