import { create } from "zustand";
import {
  commands,
  type ItemKind,
  type Origin,
  type ProvenanceRow,
  type Scope,
} from "@/bindings";
import { READ_PENDING, type ReadState, readOf } from "@/lib/read-state";
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
  /** How the last read went. A failure keeps the rows it had and says why:
   * the delete dialog's note and the places tab's Remove gate on it, and
   * acting on rows nothing confirmed is the fail-open they close. */
  read: ReadState;
  /** True while a read is out, and while a re-read is still to come behind
   * it: the rows are about to be replaced either way. */
  reading: boolean;
  load: () => Promise<void>;
  /** Read the join again, or join the read already out and take the one
   * re-read behind it. `rescanEverything` calls this, which is how a write
   * anywhere reaches every reader of the join.
   *
   * How it went is published as [read] and [reading] rather than returned,
   * so a caller re-renders when the answer lands instead of holding a
   * boolean that was true for one instant. [joinCurrent] is the pair read
   * as the one question a gating caller asks. */
  reload: () => Promise<void>;
}

/** Whether the rows are a landed read's answer with none on its way: true
 *  only there, so never read, failed, and about to be replaced are all
 *  false. Anything about to act irreversibly on the join asks this. */
export const joinCurrent = (state: ProvenanceState): boolean =>
  state.read.status === "landed" && !state.reading;

/** Where every installation came from — the Library's From column and a
 * marketplace's Installed in column read this join and match rows into their
 * groups. One standing answer, refreshed by `lib/rescan.ts` rather than by
 * each reader deciding for itself when an install might have happened. */
export const useProvenanceStore = create<ProvenanceState>((set, get) => {
  // The read out and the one re-read waiting behind it — the same pair the
  // scan store keeps, for the same reason. Requests overlap on every
  // ordinary path; the reads they ask for do not, because `reload` starts
  // one only with both handles clear. That guard is the whole of why the
  // last read to land is the last to have begun, and so the whole of why
  // there is no ranking to keep: loosen it and the ordering goes with it.
  let inFlight: Promise<void> | null = null;
  let queued: Promise<void> | null = null;

  const land = async (): Promise<void> => {
    // The wrapper folds a rejected command into an error status, so
    // `settled` is the last guard rather than the first: it names a refusal
    // that carries no reason, and a read that never answered at all is
    // still a failed read rather than a rejection for every caller of this
    // store to catch. A failure keeps the rows it had, per [ReadState].
    const response = await settled(commands.libraryProvenance());
    set(
      response.status === "ok"
        ? { rows: response.data, loaded: true, read: readOf(response) }
        : { read: readOf(response) },
    );
  };

  const start = (): Promise<void> => {
    const running = land().finally(() => {
      if (inFlight === running) inFlight = null;
      // Not simply false: a re-read waiting behind this one is about to
      // replace these rows, so nothing may call them current yet.
      set({ reading: queued !== null });
    });
    inFlight = running;
    set({ reading: true });
    return running;
  };

  return {
    rows: [],
    loaded: false,
    read: READ_PENDING,
    reading: false,
    load: async () => {
      await get().reload();
    },
    // A read already out cannot answer for what has happened since it
    // began, which is the whole of what a write behind it needs read. So an
    // overlapping request takes a re-read behind the one running. Exactly
    // one waits, a second arrival joining that one rather than stacking
    // identical whole-machine reads.
    reload: () => {
      // Both handles, not just the running one. A read hands `inFlight`
      // back before the re-read behind it starts — the continuation that
      // starts it is registered on that same promise — so a request
      // arriving in that gap would see nothing running and start a second
      // read alongside the one already scheduled. `start` is reachable
      // only with both clear, which is what makes one-at-a-time true.
      if (queued) return queued;
      if (!inFlight) return start();
      queued = inFlight.then(() => {
        queued = null;
        return start();
      });
      return queued;
    },
  };
});

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
