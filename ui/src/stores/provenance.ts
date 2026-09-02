import { create } from "zustand";
import {
  commands,
  type ItemKind,
  type Origin,
  type ProvenanceRow,
  type Scope,
} from "@/bindings";
import {
  READ_PENDING,
  type ReadState,
  readOf,
  readOrder,
} from "@/lib/read-state";
import { scopeKey } from "@/lib/scope";
import { settled } from "@/lib/settled";

interface ProvenanceState {
  rows: ProvenanceRow[];
  /** Whether a read has ever landed. Never whether the rows are current:
   * `rescanEverything` refreshes them behind every write that calls it, but
   * a read that failed leaves the previous rows in place and `loaded` true,
   * which is the right answer for a column and the wrong one for a decision.
   */
  loaded: boolean;
  /** How the last read of the join went. A failure keeps the rows it had
   * and says why: a delete dialog naming where to get the package again and
   * a places tab drawing Remove both gate on this, and acting on rows
   * nothing confirmed is exactly the fail-open that gate closes. */
  read: ReadState;
  /** True while a read of the join is on its way: a mount, a rescan behind
   * a write and a dialog opening all ask, and the rows under a reader's
   * buttons are about to be replaced. */
  reading: boolean;
  load: () => Promise<void>;
  /** Read the join again. `rescanEverything` calls this, which is how a
   * write anywhere reaches every reader of the join without any of them
   * guessing at when something installed.
   *
   * How the read went is published as [read] and [reading] rather than
   * returned: the answer belongs to the store and not to the call, so a
   * caller whose own read was overtaken re-renders when the read that
   * overtook it lands, instead of holding a boolean that was true for one
   * instant. [joinCurrent] is that pair read as the one question a caller
   * gating on the join asks. */
  reload: () => Promise<void>;
}

/** Whether `rows` is the newest read's answer with nothing newer on its
 *  way. False covers both halves: a read that failed, and a read still
 *  coming that will replace these rows. Anything about to act irreversibly
 *  on the join — a delete naming the places it will remove — asks this,
 *  because rows nothing has confirmed are indistinguishable from rows a
 *  read confirmed. */
export const joinCurrent = (state: ProvenanceState): boolean =>
  state.read.status === "landed" && !state.reading;

/** The join's reads in the order they were asked for, so the newest answer
 * is the one on screen. Several are routinely out at once: `rescanEverything`
 * refreshes the join behind every write while the Scan again buttons, a
 * delete dialog opening and a marketplace table mounting all ask for their
 * own, and the slower read is not the truer one. */
const order = readOrder();

/** Where every installation came from — the Library's From column and a
 * marketplace's Installed in column read this join and match rows into their
 * groups. One standing answer, refreshed by `lib/rescan.ts` rather than by
 * each reader deciding for itself when an install might have happened. */
export const useProvenanceStore = create<ProvenanceState>((set, get) => ({
  rows: [],
  loaded: false,
  read: READ_PENDING,
  reading: false,
  load: async () => {
    await get().reload();
  },
  reload: async () => {
    const ticket = order.begin();
    set({ reading: true });
    try {
      // `settled` lands a rejected call as the same failed read as a
      // returned refusal: the generated wrapper rethrows a transport
      // failure, and a read that never answered is a failed read, not a
      // rejection for every caller to catch.
      //
      // Called through a `then` because the wrapper reaches Tauri as it is
      // CALLED, so a page with nothing behind that call throws where a
      // promise was expected. Nothing awaits this read — `writingRepo`
      // starts it with `void` — so a throw escaping here is an unhandled
      // rejection at the window rather than a read that failed.
      const response = await settled<ProvenanceRow[]>(
        Promise.resolve().then(() => commands.libraryProvenance()),
      );
      // The newest read owns the answer, whatever it says. An older one
      // landing behind it writes nothing, rows and read state alike; a
      // failed newest read leaves the rows it had standing and says why
      // nothing confirmed them, which is [ReadState]'s own contract. So the
      // rows an overtaken read answered with are dropped even where the
      // read that overtook it failed: they are older than the state that
      // failure is about, and preferring them would need a second rank
      // beside the ticket.
      if (!order.lands(ticket)) return;
      set(
        response.status === "ok"
          ? { rows: response.data, loaded: true, read: readOf(response) }
          : { read: readOf(response) },
      );
    } finally {
      // Not simply false: another read begun behind this one is still out,
      // and the rows are still about to be replaced.
      set({ reading: order.outstanding() });
    }
  },
}));

/** Every origin recorded across these scopes, in row order. Each place
 * records its own source, so one package installed in several places can
 * carry several origins — a reader acting on all of them at once has to
 * see all of them. */
export function originsFor(
  rows: ProvenanceRow[],
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): Origin[] {
  const keys = new Set(scopes.map(scopeKey));
  return rows
    .filter(
      (row) =>
        row.kind === kind && row.name === name && keys.has(scopeKey(row.scope)),
    )
    .map((row) => row.origin);
}

/** The origin one library group shows: the first provenance row matching its
 * kind, name, and any of its scopes. Groups collapse installations that all
 * come from one place, so any match speaks for the group. Anything acting on
 * the places one at a time wants `originsFor` instead. */
export function originFor(
  rows: ProvenanceRow[],
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): Origin | null {
  return originsFor(rows, kind, name, scopes)[0] ?? null;
}

/** How an origin reads in the From column and its filter. */
export function originLabel(origin: Origin | null): string {
  if (!origin) return "";
  if (origin.origin === "marketplace") return origin.source;
  if (origin.origin === "own") return "Your own";
  return "Not managed";
}

/** The hover detail: the repo behind a marketplace, or what a fork replaced. */
export function originTitle(origin: Origin | null): string | undefined {
  if (!origin) return undefined;
  if (origin.origin === "marketplace") return origin.repo;
  if (origin.origin === "own" && origin.forkedFrom)
    return `forked from ${origin.forkedFrom}`;
  return undefined;
}
