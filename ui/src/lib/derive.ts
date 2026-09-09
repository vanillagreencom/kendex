import type {
  HarnessId,
  ItemKind,
  ObservedItem,
  PackageRef,
  ScanResult,
  Scope,
  Tag,
} from "@/bindings";
import { KINDS } from "@/lib/labels";
import type { PackageOf } from "@/lib/package-identity";
import { sameScope } from "@/lib/scope";

export type ScopeSelection = "all" | "global" | { project: string };

/** One place as the narrowing that shows only that place. Every link from a
 *  place to what is installed there states the same narrowing, so the page
 *  it opens cannot show a different set than the row that opened it. */
export const selectionOf = (scope: Scope): ScopeSelection =>
  scope.scope === "global" ? "global" : { project: scope.root };

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

interface ItemFilter {
  scope: ScopeSelection;
  harness?: string;
  tag?: Tag;
  search?: string;
}

/** Narrowings that are true of one installation: where it is, which tool
 *  reads it, what its author said it is for. Which kind of package it is
 *  is not one of them — a tool stores a package under whatever kind it can
 *  load, so that question is answered of the group, in {@link groupsOfKind}. */
export function filterItems(
  items: ObservedItem[],
  filter: ItemFilter,
): ObservedItem[] {
  const needle = filter.search?.trim().toLowerCase();
  return items.filter((item) => {
    if (!scopeMatches(item, filter.scope)) return false;
    if (filter.harness && item.harness !== filter.harness) return false;
    if (filter.tag && !item.tags.includes(filter.tag)) return false;
    if (needle) {
      const haystack = `${item.name} ${item.description ?? ""}`.toLowerCase();
      if (!haystack.includes(needle)) return false;
    }
    return true;
  });
}

/** The groups of one kind — the package's kind, which is what the filter
 *  beside it names and what the row shows. */
export const groupsOfKind = (
  groups: ItemGroup[],
  kind: ItemKind,
): ItemGroup[] => groups.filter((group) => group.kind === kind);

/** One package with every installation observed for it. */
export interface ItemGroup {
  key: string;
  /** The package these installations are, where the records establish
   *  one, and null where they do not. Null is not "unmanaged": it says
   *  nothing recorded writing this, so it answers only for itself. */
  package: PackageRef | null;
  /** The package's kind and name where one was established, and what the
   *  scan saw where none was — the identity every reader, count, link and
   *  action of this group speaks. */
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

/** One path several harnesses read, and which ones read it. */
export interface SharedFile {
  /** Where the bytes are. */
  path: string;
  /** The harness ids reading that path, in the order they were observed. */
  harnesses: string[];
}

/** Where one installation's bytes actually are, rather than where its tool
 *  looks for them: two tools linking to one shared folder read one file,
 *  though each has a path of its own pointing at it. A broken link has
 *  nothing to resolve and keeps the text it was given, which is what names
 *  the problem.
 *
 *  The one answer to "is this the same file": the Shared files chip reads
 *  it, and so does the row an installation nothing recorded belongs to, so
 *  a chip can never say two tools share a file that the table has already
 *  put on separate rows. */
export function bytesAt(install: ObservedItem): string {
  return install.fileState.state === "symlink" && !install.fileState.broken
    ? install.fileState.target
    : install.path;
}

/** The paths more than one harness reads, out of one item's installations.
 *
 * The badge that says a package is shared and the flyout that says which
 * files reads this one answer, so the badge can never stand over a list
 * that disagrees with it. */
export function sharedFiles(installations: ObservedItem[]): SharedFile[] {
  const byPath = new Map<string, string[]>();
  for (const install of installations) {
    const real = bytesAt(install);
    const harnesses = byPath.get(real) ?? [];
    if (!harnesses.includes(install.harness)) harnesses.push(install.harness);
    byPath.set(real, harnesses);
  }
  return [...byPath.entries()]
    .filter(([, harnesses]) => harnesses.length > 1)
    .map(([path, harnesses]) => ({ path, harnesses }));
}

/** Every installation on screen, gathered under the package it is.
 *
 *  A tool storing a package as another kind, or under a name of its own,
 *  is an installation detail: the row is the package, and the tools it is
 *  installed on sit on that row.
 *
 *  Where nothing establishes which package an installation is, the file it
 *  reads is all there is to go on, so that is what gathers it. Several
 *  tools reading one file are one row — the shared tree, and the links
 *  into it — while two files that merely happen to share a kind and a name
 *  are two, because nothing says they are the same thing and a name is not
 *  evidence. */
export function groupItems(
  items: ObservedItem[],
  packageOf: PackageOf,
): ItemGroup[] {
  const groups = new Map<string, ItemGroup>();
  for (const item of items) {
    const identity = packageOf(item);
    // Prefixed apart: a package and an observation are different claims
    // about what a row is, and a package named for what some unrecorded
    // file happens to be called must not join that file's row.
    const key = identity
      ? `package:${identity.kind}:${identity.name}`
      : `observed:${item.kind}:${item.name}:${bytesAt(item)}`;
    let group = groups.get(key);
    if (!group) {
      group = {
        key,
        package: identity,
        kind: identity?.kind ?? item.kind,
        name: identity?.name ?? item.name,
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
    group.shared = sharedFiles(group.installations).length > 0;
    const times = group.installations
      .map((i) => i.modifiedAt)
      .filter((t): t is number => t != null);
    group.modifiedAt = times.length > 0 ? Math.max(...times) : null;
  }
  // Ordered by what the table shows — its type column, then its name — so
  // rows of one type stay adjacent. Whether a row is a package the records
  // account for is identity, not an order a reader can see, so the key only
  // settles two rows the displayed columns cannot.
  return [...groups.values()].sort(
    (a, b) =>
      a.kind.localeCompare(b.kind) ||
      a.name.localeCompare(b.name) ||
      a.key.localeCompare(b.key),
  );
}

/** Which of the two things a row can be. A package the records account for
 *  and an installation nothing recorded can wear the same kind and name and
 *  are not the same thing, so every link to a row states which it meant
 *  rather than leaving the page to pick. */
export type PackageIdentity = "recorded" | "observed";

export const identityOf = (group: ItemGroup): PackageIdentity =>
  group.package ? "recorded" : "observed";

/** What a package is called and which of the two things wearing that kind
 *  and name it is — the shape every join, link and page selection takes,
 *  so none of them can key on half of it. */
export interface PackageIdentityRef {
  kind: ItemKind;
  name: string;
  identity: PackageIdentity;
  /** Which file, for a row nothing recorded. Its kind and name are not its
   *  identity — another file can wear both — so the file it reads is what
   *  tells one such row from another, and a link without it would open
   *  whichever came first. Absent on a recorded row, whose declaration is
   *  its identity wherever its copies sit. */
  at?: string;
}

/** How a group names itself to every join and every link. */
export const groupRef = (group: ItemGroup): PackageIdentityRef =>
  group.package
    ? { kind: group.kind, name: group.name, identity: "recorded" }
    : {
        kind: group.kind,
        name: group.name,
        identity: "observed",
        // Every installation on an unrecorded row reads one file — that is
        // what gathered them — so the first speaks for the row.
        at: group.installations[0] && bytesAt(group.installations[0]),
      };

/** The row a link opens, out of the rows on this machine.
 *
 *  What the link stated is what opens, and once the identity read has
 *  answered nothing else may: their files, tools and comparison come from
 *  one row and their versions, update note and Delete from the other, so a
 *  row that merely shares a kind and a name is a different thing, not a
 *  near miss. A package the link named that is no longer installed is
 *  nothing here, which is what sends the page back.
 *
 *  `known` is whether that read has answered. Before it has, every row
 *  reads as unrecorded whatever it is, so a recorded link would match
 *  nothing; the only row wearing this kind and name opens instead, and the
 *  page draws rather than bouncing off a state that is about to change. */
export function groupFor(
  groups: ItemGroup[],
  ref: PackageIdentityRef,
  known: boolean,
): ItemGroup | null {
  const named = groups.filter(
    (group) => group.kind === ref.kind && group.name === ref.name,
  );
  // A recorded link is answered by the identity alone; an unrecorded one
  // also has to name the file, because two rows can wear one kind and name
  // and neither is the other's stand-in.
  const exact = named.find(
    (group) =>
      identityOf(group) === ref.identity &&
      (ref.identity === "recorded" || groupRef(group).at === ref.at),
  );
  if (exact || known) return exact ?? null;
  return named.length === 1 ? named[0] : null;
}

/** How many packages a grouped scan holds — one per kind+name group, the
 *  unit the Library shows a row per. Home's Installed tile and the
 *  Library's total both count through this, so the tile can never disagree
 *  with the table it opens: a package applied to two harnesses is one
 *  package, not two. Takes the groups a caller already has, so counting
 *  never costs a second grouping pass. */
export function installedCount(groups: ItemGroup[]): number {
  return groups.length;
}

/** Where a count is being taken: everything the Library narrows by when a
 *  kind badge there is clicked, less the kind the badge itself names. A
 *  surface hands one of these to {@link installedCountByKind} and the same
 *  one to the link it draws, so the number and the page it opens cannot
 *  describe different views. */
export interface ItemPlace {
  scope?: ScopeSelection;
  harness?: HarnessId;
}

/** How many packages a place holds of each kind — one per kind+name group,
 *  the unit the Library shows a row per, counted over the place's own
 *  narrowing so a badge's number is the row count on the page its click
 *  opens. A package installed on two harnesses, or in two locations, is one
 *  package here as it is there. A kind the place holds nothing of is absent
 *  rather than zero: the badges are what a place has, not a checklist of
 *  what it hasn't. */
export function installedCountByKind(
  items: ObservedItem[],
  place: ItemPlace,
  packageOf: PackageOf,
): Map<ItemKind, number> {
  const tally = new Map<ItemKind, number>();
  const here = filterItems(items, {
    scope: place.scope ?? "all",
    harness: place.harness,
  });
  for (const group of groupItems(here, packageOf)) {
    tally.set(group.kind, (tally.get(group.kind) ?? 0) + 1);
  }
  // Handed back in the app's kind order, not the grouping's: the badges sit
  // beside the Library's own kind filter, and a reader must meet one order.
  // `groupItems` orders by kind, which is the wire order {@link KINDS}
  // exists to keep off screen.
  const counts = new Map<ItemKind, number>();
  for (const kind of KINDS) {
    const count = tally.get(kind);
    if (count) counts.set(kind, count);
  }
  return counts;
}

/** The installation belonging to one place, where the group has one.
 *
 *  A package can be installed in several places and a page names one of
 *  them, so everything that reads a file — the actions, the comparison —
 *  reads that place's copy. Another place's is a different tool's path
 *  and a different rendering. */
export function installationAt(
  group: ItemGroup | null | undefined,
  scope: Scope | null | undefined,
): ObservedItem | undefined {
  if (!group || !scope) return undefined;
  return group.installations.find((install) => sameScope(install.scope, scope));
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

function projectScopes(result: ScanResult): string[] {
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
