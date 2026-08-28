import { commands, type ItemWarning, type UpdateRow } from "@/bindings";
import { settled } from "@/lib/settled";
import { landings } from "./landings";
import { type PendingFollow, withPending } from "./updates-follow";

type Overview = {
  rows: UpdateRow[];
  warnings: ItemWarning[];
  lastFetched: number | null;
};
type OverviewResult =
  | { status: "ok"; data: Overview }
  | { status: "error"; error: string };

// The one place a read of the standing lands, however it went. A failure
// — a returned refusal and a rejected call alike, via `settled` — marks
// the data stale (loaded = false) and keeps why (error) rather than
// leaving the last-good rows trusted: the package page gates the Update
// button on `loaded`, and acting on rows we could not refresh is exactly
// the fail-open this closes. Returns why the read failed, or null, so
// callers make their own noise.
//
// Two ordering rules, by what produced the overview:
//
// - Plain reads run concurrently and rank by when they began (see
//   `landings`): a slow early read landing last is discarded rather than
//   overwriting a fresher answer.
// - Side-effecting operations — a refresh that fetches every source, a
//   mutation that commits a change — run one at a time on a chain: the
//   next command is not sent until the previous answer has landed, so
//   their landings are in commit order by construction and no rank rule
//   between them is needed. Each landing is authoritative over every
//   plain read begun before it, success and refresh-failure alike — an
//   explicit check that failed is an answer to report, not one a quicker
//   re-read of old mirrors may bury. Only a failed mutation touches
//   nothing: it re-read nothing, and the rows on screen are still the
//   last good read's answer.
//
// A `settle` is a mutation that holds one scope instead of the page: the
// Follow source switch has already moved, the store marks that scope as
// settling, and every other row stays live for as long as the write runs.
export function overviewApplier(
  set: (partial: {
    rows?: UpdateRow[];
    warnings?: ItemWarning[];
    loaded?: boolean;
    error?: string | null;
    overviewInFlight?: boolean;
    lastFetched?: number | null;
  }) => void,
  /** The follow flips whose writes have not answered — every landing wears
   *  them, so a read that began before a flip cannot bounce the switch. */
  pending: () => PendingFollow[],
) {
  const order = landings();
  let chain: Promise<unknown> = Promise.resolve();
  // A plain read, a refresh, and a mutation are each about to replace
  // every row on screen: the store's overviewInFlight says so while any is
  // outstanding, and the commit-applying actions refuse for as long as it
  // is up. A settle replaces them too but holds only its own scope, so it
  // is counted here by the store's pending flips instead.
  let inFlight = 0;

  // A read that failed keeps the age it had along with the rows it had: a
  // check that could not run fetched nothing, so the last fetch is still
  // when these rows were last true.
  const landOk = (data: Overview) =>
    set({
      rows: withPending(data.rows, pending()),
      warnings: data.warnings,
      lastFetched: data.lastFetched,
      loaded: true,
      error: null,
    });

  return async (
    read: () => Promise<OverviewResult>,
    kind: "read" | "refresh" | "mutation" | "settle" = "read",
  ): Promise<string | null> => {
    // A settle's own scope holds through the store's pending flips; raising
    // the page-wide flag too would disable every unrelated row for the
    // whole of the write it is running in the background.
    const holdsPage = kind !== "settle";
    if (holdsPage) {
      inFlight += 1;
      set({ overviewInFlight: true });
    }
    try {
      if (kind === "read") {
        const ticket = order.begin();
        const response = await settled<Overview>(Promise.resolve().then(read));
        if (order.land(ticket)) {
          if (response.status === "ok") landOk(response.data);
          else set({ loaded: false, error: response.error });
        }
        return response.status === "ok" ? null : response.error;
      }
      const turn = chain.then(async (): Promise<string | null> => {
        const response = await settled<Overview>(Promise.resolve().then(read));
        if (response.status === "ok") {
          order.landAuthoritative();
          landOk(response.data);
          return null;
        }
        if (kind === "refresh") {
          order.landAuthoritative();
          set({ loaded: false, error: response.error });
          return response.error;
        }
        // A mutation can commit and then fail building its overview: the
        // rows on screen may no longer be the truth, so one reconciling
        // read answers either way — success lands whatever actually
        // committed, failure marks the retained rows stale under the
        // operation's own error. The handed operation's error returns
        // either way; a caller whose work ran apart from this read
        // (`mutate`) owns telling a dead read from a failed work.
        const reread = await settled<Overview>(commands.updatesOverview());
        order.landAuthoritative();
        if (reread.status === "ok") landOk(reread.data);
        else set({ loaded: false, error: response.error });
        return response.error;
      });
      // The chain outlives a link that throws; the error still reaches
      // this operation's caller through `turn`.
      chain = turn.catch(() => {});
      return await turn;
    } finally {
      if (holdsPage) {
        inFlight -= 1;
        if (inFlight === 0) set({ overviewInFlight: false });
      }
    }
  };
}
