import { create } from "zustand";
import {
  commands,
  type Origin,
  type ProvenanceRow,
  type Scope,
} from "@/bindings";
import type { PackageIdentityRef } from "@/lib/derive";
import { READ_PENDING, type ReadState, readOf } from "@/lib/read-state";
import { scopeKey } from "@/lib/scope";
import { settled } from "@/lib/settled";
import { useScanStore } from "@/stores/scan";

interface ProvenanceState {
  rows: ProvenanceRow[];
  /** Whether a read has ever landed. Never whether the rows are current:
   * `rescanEverything` refreshes them behind every write that calls it, but
   * a read that failed leaves the previous rows in place and `loaded` true,
   * which is the right answer for a column and the wrong one for a decision.
   */
  loaded: boolean;
  /** The scan `rows` answer about: the generation standing when this read
   *  began. A read that began before a scan landed describes the machine
   *  before it, so its rows are not an answer about what is on screen now
   *  — which `loaded` alone can never say, because it only means a read
   *  once landed. Null until one has. */
  answeredFor: number | null;
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
  /** Make the join answer for one scan, once.
   *
   *  The single entry point for "a scan landed, so read the join behind
   *  it". Two callers ask — the rescan that published the scan, and the
   *  app's own effect watching for scans it did not start — and asking
   *  twice costs a second whole-machine read whose failure would replace
   *  the first read's success. Already answered for that scan, or already
   *  reading toward it, is nothing to do. */
  ensureFor: (generation: number) => Promise<void>;
}

/** Whether the rows are a landed read's answer with none on its way: true
 *  only there, so never read, failed, and about to be replaced are all
 *  false. Anything about to act irreversibly on the join asks this. */
export const joinCurrent = (state: ProvenanceState): boolean =>
  state.read.status === "landed" &&
  !state.reading &&
  // And about the scan on screen. A landed idle read of the scan BEFORE
  // this one is not an answer about what is on the page now, and this is
  // the predicate an irreversible action asks.
  state.answeredFor === useScanStore.getState().generation;

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
  // The scan the read now out is answering about, or null with none out.
  // Whether a read is running says nothing about which machine it will
  // describe: one that began before the current scan landed will land with
  // an answer about the scan before it, so [ensureFor] has to ask what it
  // is answering rather than whether anything is.
  let asking: number | null = null;

  const land = async (): Promise<void> => {
    // Taken as the read begins, not as it lands: what these rows describe
    // is the machine at the moment they were asked for, and a scan landing
    // while the read is out is a scan they know nothing about.
    const asked = useScanStore.getState().generation;
    asking = asked;
    // The wrapper folds a rejected command into an error status, so
    // `settled` is the last guard rather than the first: it names a refusal
    // that carries no reason, and a read that never answered at all is
    // still a failed read rather than a rejection for every caller of this
    // store to catch. A failure keeps the rows it had, per [ReadState].
    const response = await settled(commands.libraryProvenance());
    set(
      response.status === "ok"
        ? {
            rows: response.data,
            loaded: true,
            answeredFor: asked,
            read: readOf(response),
          }
        : { read: readOf(response) },
    );
  };

  const start = (): Promise<void> => {
    const running = land().finally(() => {
      if (inFlight === running) {
        inFlight = null;
        asking = null;
      }
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
    answeredFor: null,
    read: READ_PENDING,
    reading: false,
    load: async () => {
      await get().reload();
    },
    ensureFor: async (generation) => {
      if (get().answeredFor === generation) return;
      // A read that is out answers only for the scan it began after. One
      // that began earlier will land describing that earlier machine, and
      // no state change would ask again — so it is not dedupated against,
      // and `reload` takes the one re-read behind it.
      if (asking !== null && asking >= generation) return;
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

/** Whether one row is the identity asked for.
 *
 * A recorded group asks about a package the records name, and only a row
 * naming that package answers — a row for something nothing recorded is a
 * different thing that happens to share a label. An unrecorded group asks
 * about what the scan saw, and only a row that recorded nothing answers.
 * Blurring the two lets an unmanaged file read as the marketplace package
 * beside it, or the package read as Not managed. */
const rowIs = (row: ProvenanceRow, ref: PackageIdentityRef): boolean =>
  ref.identity === "recorded"
    ? row.package?.kind === ref.kind && row.package.name === ref.name
    : row.package === null &&
      row.kind === ref.kind &&
      row.name === ref.name &&
      // The file too: two rows in one place can wear this kind and name,
      // and one may carry provenance the other does not.
      row.at === ref.at;

/** Every origin recorded across these scopes, in row order. Each place
 * records its own source, so one package installed in several places can
 * carry several origins — a reader acting on all of them at once has to
 * see all of them. */
export function originsFor(
  rows: ProvenanceRow[],
  ref: PackageIdentityRef,
  scopes: Scope[],
): Origin[] {
  const keys = new Set(scopes.map(scopeKey));
  return rows
    .filter((row) => rowIs(row, ref) && keys.has(scopeKey(row.scope)))
    .map((row) => row.origin);
}

/** The provenance record one library group shows: the first row matching its
 * kind, name, and any of its scopes. Groups collapse installations that all
 * come from one place, so any match speaks for the group. Anything acting on
 * the places one at a time wants `originsFor` instead.
 *
 * The whole row rather than its origin, because the two halves only mean
 * something together: a marketplace source is an alias declared at one
 * place, so a caller that reads the alias here and the scope from somewhere
 * else — a group's first installation, say — can address a subscription that
 * exists at neither. `originFor` is this row's origin, for the callers that
 * only draw it. */
export function provenanceFor(
  rows: ProvenanceRow[],
  ref: PackageIdentityRef,
  scopes: Scope[],
): ProvenanceRow | null {
  const keys = new Set(scopes.map(scopeKey));
  return (
    rows.find((row) => rowIs(row, ref) && keys.has(scopeKey(row.scope))) ?? null
  );
}

/** The origin one library group shows — [provenanceFor]'s row, read for the
 * one thing a column needs. */
export function originFor(
  rows: ProvenanceRow[],
  ref: PackageIdentityRef,
  scopes: Scope[],
): Origin | null {
  return provenanceFor(rows, ref, scopes)?.origin ?? null;
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
