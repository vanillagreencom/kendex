import type { ItemWarning, UpdateRow } from "@/bindings";
import { settled } from "@/lib/settled";
import { landings } from "./landings";

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
// Landings are ordered (see `landings`): the mount-time load, an explicit
// check, and a mutation's returned overview can resolve in any order, and
// a slow early read landing last would overwrite a fresher answer and
// stamp its stale rows loaded and current. A discarded landing's return
// value still reports how the operation itself went.
export function overviewApplier(
  set: (partial: {
    rows?: UpdateRow[];
    warnings?: ItemWarning[];
    loaded?: boolean;
    error?: string | null;
  }) => void,
) {
  const order = landings();
  return async (
    read: Promise<OverviewResult>,
    // A read that failed leaves the rows on screen unconfirmed; a mutation
    // that failed re-read nothing, so the rows are still the last good
    // read's answer — only reads may mark them stale. A mutation that
    // SUCCEEDED always lands: its overview reports the state after its
    // commit, which no read still in flight can be fresher than.
    opts?: { mutation?: boolean },
  ): Promise<string | null> => {
    const ticket = order.begin();
    const response = await settled(read);
    if (response.status === "ok") {
      const lands = opts?.mutation
        ? order.landAuthoritative()
        : order.land(ticket);
      if (lands) {
        set({
          rows: response.data.rows,
          warnings: response.data.warnings,
          loaded: true,
          error: null,
        });
      }
      return null;
    }
    if (!opts?.mutation && order.land(ticket)) {
      set({ loaded: false, error: response.error });
    }
    return response.error;
  };
}
