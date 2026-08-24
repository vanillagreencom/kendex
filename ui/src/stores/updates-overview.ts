import type { ItemWarning, UpdateRow } from "@/bindings";
import { settled } from "@/lib/settled";

type OverviewResult =
  | { status: "ok"; data: { rows: UpdateRow[]; warnings: ItemWarning[] } }
  | { status: "error"; error: string };

// The one place a read of the standing lands, however it went. A failure
// — a returned refusal and a rejected call alike, via `settled` — marks
// the data stale (loaded = false) and keeps why (error) rather than
// leaving the last-good rows trusted: the package page gates the Update
// button on `loaded`, and acting on rows we could not refresh is exactly
// the fail-open this closes. Returns why the read failed, or null, so
// callers make their own noise.
//
// Landings are ordered: the mount-time load, an explicit check, and a
// mutation's returned overview can resolve in any order, and a slow
// early read landing last would overwrite a fresher answer and stamp its
// stale rows loaded and current. Each read takes a ticket when it
// starts; a landing older than the last one written is discarded — its
// return value still reports how the operation itself went.
export function overviewApplier(
  set: (partial: {
    rows?: UpdateRow[];
    warnings?: ItemWarning[];
    loaded?: boolean;
    error?: string | null;
  }) => void,
) {
  let started = 0;
  let written = 0;
  return async (
    read: Promise<OverviewResult>,
    // A read that failed leaves the rows on screen unconfirmed; a mutation
    // that failed re-read nothing, so the rows are still the last good
    // read's answer — only reads may mark them stale.
    opts?: { mutation?: boolean },
  ): Promise<string | null> => {
    const ticket = ++started;
    const response = await settled(read);
    if (response.status === "ok") {
      if (ticket > written) {
        written = ticket;
        set({
          rows: response.data.rows,
          warnings: response.data.warnings,
          loaded: true,
          error: null,
        });
      }
      return null;
    }
    if (!opts?.mutation && ticket > written) {
      written = ticket;
      set({ loaded: false, error: response.error });
    }
    return response.error;
  };
}
