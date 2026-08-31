// How a read of the update standing lands, kept beside the store the way
// its apply and edit flows are, so the store body stays the state
// lifecycle.
import {
  commands,
  type ItemWarning,
  type UpdateRow,
  type UpdatesReport_Serialize,
} from "@/bindings";
import { type ReadState, readOf, readOrder } from "@/lib/read-state";
import { settled } from "@/lib/settled";
import { type PendingFollow, withPending } from "./updates-follow";
import { commits } from "./updates-writes";

/** The slice a landing writes, and the two it reads. */
interface Standing {
  rows: UpdateRow[];
  warnings: ItemWarning[];
  lastFetched: number | null;
  read: ReadState;
  reading: boolean;
}

type Answer =
  | { status: "ok"; data: UpdatesReport_Serialize }
  | { status: "error"; error: string };

/** The landing and the plain read, sharing one ticket order.
 *
 *  Reads of the standing overlap on every ordinary path: startup against
 *  the page's own mount, the focus rescan against both, every mutation
 *  re-reading behind them. */
export function standingReads(
  set: (partial: Partial<Standing>) => void,
  get: () => { pendingFollows: PendingFollow[] },
) {
  const order = readOrder();

  // The one place a read of the standing lands, however it went. A failure
  // — a returned refusal and a rejected call alike, via `settled` — keeps
  // the rows it had along with the age they had: a check that could not
  // run fetched nothing, so the last fetch is still when these rows were
  // last true, and `read` says they are not confirmed. The rows wear every
  // flip whose write has not answered, so a landing cannot bounce a switch
  // back under the hand that moved it.
  //
  // `ticket` ranks this answer against the other reads out: an older one
  // landing last writes nothing at all, rows and read state alike.
  const land = (ticket: number, response: Answer) => {
    if (!order.lands(ticket)) return;
    if (response.status === "ok") {
      set({
        rows: withPending(response.data.rows, get().pendingFollows),
        warnings: response.data.warnings,
        lastFetched: response.data.lastFetched,
        read: readOf(response),
      });
    } else {
      set({ read: readOf(response) });
    }
  };

  return {
    /** Begin an operation that answers with the standing itself, and take
     *  the landing for that answer.
     *
     *  The answer ranks by when it LANDS rather than when the operation
     *  began: it reports the state its own work made, so it outranks every
     *  read still in flight. That claim holds only while nothing else
     *  commits meanwhile. A command builds its report once, somewhere
     *  inside itself — `updates_refresh` fetches every mirror and reads the
     *  standing after — so a commit that landed while it was out may be
     *  missing from it, and claiming to be newest would put the rows back
     *  as they were before that commit. Whoever committed read the
     *  standing back for themselves; theirs is the newer answer.
     *
     *  Answers whether it landed, so a caller that lost can read again. */
    beginOwn: () => {
      const since = commits.since();
      return (response: Answer): boolean => {
        if (commits.stale(since)) return false;
        land(order.begin(), response);
        return true;
      };
    },
    /** Read the standing again. `reading` is up for as long as one is out,
     *  read off the same ticket that orders the landings, so the page-wide
     *  rule and the ordering rule cannot disagree. */
    reload: async () => {
      const ticket = order.begin();
      set({ reading: true });
      try {
        land(ticket, await settled(commands.updatesOverview()));
      } finally {
        // Not simply false: another reload begun behind this one is still
        // out, and the rows are still about to be replaced.
        set({ reading: order.outstanding() });
      }
    },
  };
}
