// How a read of the update standing lands, kept beside the store the way
// its apply and edit flows are, so the store body stays the state
// lifecycle.
import {
  commands,
  type ItemWarning,
  type UnreadableScope,
  type UpdateRow,
  type UpdatesReport_Serialize,
} from "@/bindings";
import { type ReadState, readOf, readOrder } from "@/lib/read-state";
import { settled } from "@/lib/settled";
import { type PendingFollow, withPending } from "./updates-follow";

/** What a read of the standing owns: the slice a landing writes, and the
 *  two flags saying how the last one went. The store spreads these into
 *  its own state rather than declaring them a second time. */
export interface Standing {
  rows: UpdateRow[];
  /** Packages whose standing could not be computed — shown, never treated
   *  as current. */
  warnings: ItemWarning[];
  /** Projects whose standing could not be read at all. One project's
   *  unreadable lock or manifest leaves every other project's rows intact,
   *  so the page names the project and sends the reader to Problems rather
   *  than going blank over the whole machine. */
  unreadable: UnreadableScope[];
  /** Unix seconds of the last successful mirror fetch behind these rows,
   *  null when nothing has ever fetched. The page dates its answer from
   *  this — the check runs offline on load, so "everything is up to date"
   *  needs the age of the fetch it rests on beside it. */
  lastFetched: number | null;
  /** How the last read of the standing went. A failure keeps the rows it
   *  had and says why: the package page gates the Update button on this,
   *  and acting on rows we could not refresh is exactly the fail-open it
   *  closes. */
  read: ReadState;
  /** True while a read of the standing is on its way: a mount or a return
   *  to the window reloads over rows that landed perfectly well, and every
   *  value a commit-applying action captured is about to be replaced. */
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
        unreadable: response.data.unreadable,
        lastFetched: response.data.lastFetched,
        read: readOf(response),
      });
    } else {
      set({ read: readOf(response) });
    }
  };

  return {
    /** Land an answer that reports the standing an operation's own work
     *  made.
     *
     *  It ranks by when it LANDS rather than when the operation began: it
     *  reports the state its own work made, so it outranks every read still
     *  in flight. What makes that safe is the store's exclusion: the check
     *  refuses while `busy`, and every write that goes through
     *  `holdingBusy` raises it, so none of those can have committed while
     *  this answer was being built. A mutation reaching the engine another
     *  way is outside what this ranks against. */
    landOwn: (response: Answer) => land(order.begin(), response),
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
