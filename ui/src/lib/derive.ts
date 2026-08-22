import type {
  ItemKind,
  ItemSafety,
  ObservedItem,
  ScanResult,
  Scope,
  Tag,
} from "@/bindings";

export type ScopeSelection = "all" | "global" | { project: string };

export function scopeLabel(scope: Scope): string {
  return scope.scope === "global" ? "global" : scope.root;
}

export function scopeMatches(
  item: ObservedItem,
  selection: ScopeSelection,
): boolean {
  if (selection === "all") return true;
  if (selection === "global") return item.scope.scope === "global";
  return (
    item.scope.scope === "project" && item.scope.root === selection.project
  );
}

export interface ItemFilter {
  scope: ScopeSelection;
  kind?: ItemKind;
  harness?: string;
  tag?: Tag;
  search?: string;
}

export function filterItems(
  items: ObservedItem[],
  filter: ItemFilter,
): ObservedItem[] {
  const needle = filter.search?.trim().toLowerCase();
  return items.filter((item) => {
    if (!scopeMatches(item, filter.scope)) return false;
    if (filter.kind && item.kind !== filter.kind) return false;
    if (filter.harness && item.harness !== filter.harness) return false;
    if (filter.tag && !item.tags.includes(filter.tag)) return false;
    if (needle) {
      const haystack = `${item.name} ${item.description ?? ""}`.toLowerCase();
      if (!haystack.includes(needle)) return false;
    }
    return true;
  });
}

/** One logical item (kind + name) with every installation observed for it. */
export interface ItemGroup {
  key: string;
  kind: ItemKind;
  name: string;
  description: string | null;
  installations: ObservedItem[];
  harnesses: string[];
  /** Every tag any installation of this item carries, deduped. One item can
   *  be installed from copies that disagree; the union is what it is for. */
  tags: Tag[];
  /** True when several harnesses read the same physical artifact. */
  shared: boolean;
  /** Most recent installation mtime, or null when none of them have one. */
  modifiedAt: number | null;
}

export function groupItems(items: ObservedItem[]): ItemGroup[] {
  const groups = new Map<string, ItemGroup>();
  for (const item of items) {
    const key = `${item.kind}:${item.name}`;
    let group = groups.get(key);
    if (!group) {
      group = {
        key,
        kind: item.kind,
        name: item.name,
        description: item.description,
        installations: [],
        harnesses: [],
        tags: [],
        shared: false,
        modifiedAt: null,
      };
      groups.set(key, group);
    }
    group.installations.push(item);
    group.description ??= item.description;
    if (!group.harnesses.includes(item.harness))
      group.harnesses.push(item.harness);
    for (const tag of item.tags) {
      if (!group.tags.includes(tag)) group.tags.push(tag);
    }
  }
  for (const group of groups.values()) {
    // Where the bytes actually are, not where the harness looks for them: two
    // harnesses linking to one shared folder are sharing a file, even though
    // each has a path of its own pointing at it.
    const byPath = new Map<string, Set<string>>();
    for (const install of group.installations) {
      const real =
        install.fileState.state === "symlink" && !install.fileState.broken
          ? install.fileState.target
          : install.path;
      const set = byPath.get(real) ?? new Set();
      set.add(install.harness);
      byPath.set(real, set);
    }
    group.shared = [...byPath.values()].some((harnesses) => harnesses.size > 1);
    const times = group.installations
      .map((i) => i.modifiedAt)
      .filter((t): t is number => t != null);
    group.modifiedAt = times.length > 0 ? Math.max(...times) : null;
  }
  return [...groups.values()].sort((a, b) => a.key.localeCompare(b.key));
}

/** Who ships this item, when a tool ships it itself — the vendor named by
 *  every installation, or null the moment they disagree or none says. */
export function groupVendor(group: ItemGroup): string | null {
  const vendor = group.installations[0]?.vendor ?? null;
  if (!vendor) return null;
  return group.installations.every((install) => install.vendor === vendor)
    ? vendor
    : null;
}

/** Every distinct scope a group's installations live in, in first-seen order. */
export function groupScopes(group: ItemGroup): Scope[] {
  const seen = new Map<string, Scope>();
  for (const install of group.installations) {
    const key = scopeLabel(install.scope);
    if (!seen.has(key)) seen.set(key, install.scope);
  }
  return [...seen.values()];
}

export function countByKind(items: ObservedItem[]): Map<ItemKind, number> {
  const counts = new Map<ItemKind, number>();
  for (const item of items) {
    counts.set(item.kind, (counts.get(item.kind) ?? 0) + 1);
  }
  return counts;
}

export function projectScopes(result: ScanResult): string[] {
  const roots = new Set<string>();
  for (const item of result.items) {
    if (item.scope.scope === "project") roots.add(item.scope.root);
  }
  return [...roots].sort();
}

/** The places the Library offers to look: every project with something
 * installed, plus the one being looked at. A project can be picked before it
 * holds anything — from its card on Projects, or by emptying it while the
 * table is open — and a place with no pill would leave an empty table with
 * nothing on screen saying where it is looking. */
export function scopeChoices(
  result: ScanResult | null,
  selection: ScopeSelection,
): string[] {
  const roots = new Set(result ? projectScopes(result) : []);
  if (selection !== "all" && selection !== "global") {
    roots.add(selection.project);
  }
  return [...roots].sort();
}

// An item whose findings someone read and accepted is installed and staying,
// so calling it held back would be the opposite of the truth. Only a block
// with no live acceptance behind it is held back.
export function heldBack(row: ItemSafety): boolean {
  return row.verdict === "block" && row.override.state !== "active";
}

/** A group known to have a modification time, once {@link recentItems} has
 * filtered out the ones that don't. */
export type RecentGroup = ItemGroup & { modifiedAt: number };

/** The most recently modified groups, newest first — groups with no
 * observed mtime have nothing to say about "recent" and are left out. */
export function recentItems(groups: ItemGroup[], limit: number): RecentGroup[] {
  return groups
    .filter((g): g is RecentGroup => g.modifiedAt != null)
    .sort((a, b) => b.modifiedAt - a.modifiedAt)
    .slice(0, limit);
}

/** What a bundle carries, short enough to sit under its name. */
export function bundleSummary(members: string[]): string {
  if (members.length === 0) return "Carries nothing yet";
  const shown = members.slice(0, 4).join(", ");
  const rest = members.length - 4;
  return rest > 0 ? `${shown}, and ${rest} more` : shown;
}

/** How an installed package is doing, in one word. A broken link outranks
 *  a switch: the file it points at is gone whatever the switch says. */
export type GroupStatus = "active" | "off" | "broken";

export function groupStatus(group: ItemGroup): GroupStatus {
  const broken = group.installations.some(
    (i) => i.fileState.state === "symlink" && i.fileState.broken,
  );
  if (broken) return "broken";
  return group.installations.some((i) => i.enabled === false)
    ? "off"
    : "active";
}
