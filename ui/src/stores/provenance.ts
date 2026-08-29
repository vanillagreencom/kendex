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
  loaded: boolean;
  load: () => Promise<void>;
}

/** Where every installation came from — the Library's From column reads
 * this join once and matches rows into its groups. */
export const useProvenanceStore = create<ProvenanceState>((set) => ({
  rows: [],
  loaded: false,
  load: async () => {
    const response = await commands.libraryProvenance();
    if (response.status === "ok") {
      set({ rows: response.data, loaded: true });
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
