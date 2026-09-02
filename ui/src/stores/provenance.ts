import { create } from "zustand";
import {
  commands,
  type ItemKind,
  type Origin,
  type ProvenanceRow,
  type Scope,
} from "@/bindings";
import { scopeKey } from "@/lib/scope";

interface ProvenanceState {
  rows: ProvenanceRow[];
  /** Whether a read has ever landed. Never whether the rows are current:
   * `rescanEverything` refreshes them behind every write that calls it, but
   * a read that failed leaves the previous rows in place and `loaded` true,
   * which is the right answer for a column and the wrong one for a decision.
   */
  loaded: boolean;
  load: () => Promise<void>;
  /** Read the join again and say whether it landed. `rescanEverything` calls
   * this, which is how a write anywhere reaches every reader of the join
   * without any of them guessing at when something installed. Anything about
   * to act irreversibly on the answer — a delete naming the places it will
   * remove — still asks for its own read and waits on this boolean, because
   * a refresh that failed is indistinguishable from one that changed
   * nothing. */
  reload: () => Promise<boolean>;
}

/** Where every installation came from — the Library's From column and a
 * marketplace's Installed in column read this join and match rows into their
 * groups. One standing answer, refreshed by `lib/rescan.ts` rather than by
 * each reader deciding for itself when an install might have happened. */
export const useProvenanceStore = create<ProvenanceState>((set, get) => ({
  rows: [],
  loaded: false,
  load: async () => {
    await get().reload();
  },
  reload: async () => {
    try {
      const response = await commands.libraryProvenance();
      if (response.status !== "ok") return false;
      set({ rows: response.data, loaded: true });
      return true;
    } catch {
      // The generated wrapper rethrows a transport failure rather than
      // answering with an error status. A read that never answered is a
      // failed read, not a rejection for every caller to catch.
      return false;
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
