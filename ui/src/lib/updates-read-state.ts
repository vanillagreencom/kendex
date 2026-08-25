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
