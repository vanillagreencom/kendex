import { commands, type ItemWarning, type UpdateRow } from "@/bindings";
import { settled } from "@/lib/settled";
import { landings } from "./landings";

type Overview = { rows: UpdateRow[]; warnings: ItemWarning[] };
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
export function overviewApplier(
  set: (partial: {
    rows?: UpdateRow[];
    warnings?: ItemWarning[];
    loaded?: boolean;
    error?: string | null;
    overviewInFlight?: boolean;
  }) => void,
) {
  const order = landings();
  let chain: Promise<unknown> = Promise.resolve();
  // Every operation this applier runs — plain read, refresh, mutation —
  // is about to replace the rows on screen: the store's overviewInFlight
  // says so while any is outstanding, and the commit-applying actions
  // refuse for as long as it is up.
  let inFlight = 0;

  const landOk = (data: Overview) =>
    set({
      rows: data.rows,
      warnings: data.warnings,
      loaded: true,
      error: null,
    });

  return async (
    read: () => Promise<OverviewResult>,
    kind: "read" | "refresh" | "mutation" = "read",
  ): Promise<string | null> => {
    inFlight += 1;
    set({ overviewInFlight: true });
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
        // operation's own error.
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
      inFlight -= 1;
      if (inFlight === 0) set({ overviewInFlight: false });
    }
  };
}
