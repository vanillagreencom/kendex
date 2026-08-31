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
