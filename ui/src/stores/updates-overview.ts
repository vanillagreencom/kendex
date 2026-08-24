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
    // What produced this overview decides how it lands. A plain read ranks
    // by when it began, success and failure alike. A refresh fetched every
    // source before answering, and a mutation committed a change: their
    // successful answers report a state no read still in flight can be
    // fresher than, so both land authoritatively. On failure a refresh is
    // just a read that could not answer — it marks the rows stale — while
    // a failed mutation re-read nothing and touches nothing.
    kind: "read" | "refresh" | "mutation" = "read",
  ): Promise<string | null> => {
    const ticket = order.begin();
    const response = await settled(read);
    if (response.status === "ok") {
      const lands =
        kind === "read" ? order.land(ticket) : order.landAuthoritative();
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
    if (kind !== "mutation" && order.land(ticket)) {
      set({ loaded: false, error: response.error });
    }
    return response.error;
  };
}
