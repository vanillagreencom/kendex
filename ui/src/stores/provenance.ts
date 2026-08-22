import { create } from "zustand";
import {
  commands,
  type ItemKind,
  type Origin,
  type ProvenanceRow,
  type Scope,
} from "@/bindings";
import { keepIfSame } from "@/lib/same-read";
import { scopeKey } from "@/lib/scope";

interface ProvenanceState {
  rows: ProvenanceRow[];
  loaded: boolean;
  /** Why the join could not be read, or null. The From row is derived from
   *  these rows, so a failure has to be sayable rather than rendering as a
   *  row that is simply absent. */
  error: string | null;
  load: () => Promise<void>;
}

/** Where every installation came from — the Library's From column reads
 * this join once and matches rows into its groups. */
export const useProvenanceStore = create<ProvenanceState>((set) => {
  // Every read takes a ticket, and only the newest one speaks. This store
  // reads one thing one way, so its rank is arrival order: the Library
  // starts a read after every scan while the package page can start another
  // before that one lands, and without a ticket whichever returns last
  // wins — putting back provenance a newer read has already replaced, or
  // clearing an error it just set.
  let reads = 0;
  return {
    rows: [],
    loaded: false,
    error: null,
    load: async () => {
      reads += 1;
      const token = reads;
      const newest = () => token === reads;
      let response: Awaited<ReturnType<typeof commands.libraryProvenance>>;
      try {
        response = await commands.libraryProvenance();
      } catch (thrown) {
        // Both callers fire this without awaiting, so a rejection left alone
        // is unhandled and the From row simply never appears.
        if (newest()) set({ loaded: true, error: String(thrown) });
        return;
      }
      if (!newest()) return;
      if (response.status === "ok") {
        // A re-read that says the same thing hands back the array already on
        // screen: the Library keys these per place and memoizes on identity,
        // so an equal copy re-derives and re-renders the whole table.
        set((state) => ({
          rows: keepIfSame(state.rows, response.data),
          loaded: true,
          error: null,
        }));
      } else {
        // Left silent, a failure renders as a From row that simply never
        // appears — the reader is told nothing and has nothing to retry.
        set({ loaded: true, error: response.error });
      }
    },
  };
});

const originKey = (kind: ItemKind, name: string, scope: Scope): string =>
  `${kind}:${name}:${scopeKey(scope)}`;

/** Provenance keyed by the place it is about, built once per read. A table
 *  asks per group, and scanning every row for every group is the whole cost
 *  of the join at a few hundred packages. The first row for a place wins,
 *  as the scan-order search it replaces did. */
export function indexOrigins(rows: ProvenanceRow[]): Map<string, Origin> {
  const index = new Map<string, Origin>();
  for (const row of rows) {
    const key = originKey(row.kind, row.name, row.scope);
    if (!index.has(key)) index.set(key, row.origin);
  }
  return index;
}

/** The origin one library group shows. Groups collapse installations that
 * all come from one place, so the first of its scopes with a row speaks for
 * the group. */
export function originFor(
  index: Map<string, Origin>,
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): Origin | null {
  for (const scope of scopes) {
    const found = index.get(originKey(kind, name, scope));
    if (found) return found;
  }
  return null;
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
