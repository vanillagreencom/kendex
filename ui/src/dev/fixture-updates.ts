// The Updates page as the mock world sees it: every catalog install has a
// row; the first has a newer version, the second was edited by hand and
// stays that way until its copy is installed beside the source's version.
import type { ItemKind, Scope, UpdateRow } from "@/bindings";
import { store } from "./mock-state";

export const OLD = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
export const NEW = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

function installedItems() {
  return store.state.items.filter(
    (item) => item.origin !== null && item.origin !== "local",
  );
}

export function updateRows(): UpdateRow[] {
  return installedItems().map((item, index) => {
    const edited = index === 1 && !store.state.keptBeside.includes(item.name);
    return updateRow(item, index === 0 || edited, edited);
  });
}

function updateRow(
  item: { scope: Scope; kind: ItemKind; name: string; origin: string | null },
  newer: boolean,
  edited: boolean,
): UpdateRow {
  return {
    scope: item.scope,
    kind: item.kind,
    name: item.name,
    source: "kendex",
    repo: item.origin ?? "vanillagreencom/kendex",
    repoIdentity: item.origin ?? "vanillagreencom/kendex",
    current: { commit: OLD, label: "v1.0", date: "2026-08-01T10:00:00Z" },
    latest: newer
      ? { commit: NEW, label: "v1.1", date: "2026-08-14T10:00:00Z" }
      : { commit: OLD, label: "v1.0", date: "2026-08-01T10:00:00Z" },
    updateAvailable: newer,
    pinned: false,
    ignored: store.state.ignored.some(
      (entry) => entry.kind === item.kind && entry.name === item.name,
    ),
    blockedByLocalEdit: edited,
    editedHarnesses: edited ? ["claude"] : [],
    forkableHarness: edited ? "claude" : null,
    canDiscard: true,
    canTakeLatest: true,
    holdOwner: null,
    derived: false,
    forked: false,
    mixed: false,
    removedUpstream: false,
    noPerPackageUpdate: null,
  };
}
