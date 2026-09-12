import type {
  HarnessId,
  ItemKind,
  ObservedItem,
  PackageRef,
  Scope,
  Tag,
  UpdateRow,
} from "@/bindings";
import { KINDS } from "@/lib/labels";
import type { PackageOf, SummaryOf } from "@/lib/package-identity";
import { sameScope, scopeKey } from "@/lib/scope";

export type ScopeSelection = "all" | "global" | { project: string };

/** One place as the narrowing that shows only that place. Every link from a
 *  place to what is installed there states the same narrowing, so the page
 *  it opens cannot show a different set than the row that opened it. */
export const selectionOf = (scope: Scope): ScopeSelection =>
  scope.scope === "global" ? "global" : { project: scope.root };

export function scopeLabel(scope: Scope): string {
  return scope.scope === "global" ? "global" : scope.root;
}

/** Whether one thing sitting in a place is inside a narrowing. Asked of
 *  anything that names a place — an observation the scan made, a record's
 *  update row — because the narrowing is about the place and nothing else
 *  on the thing. */
export function scopeMatches(
  item: { scope: Scope },
  selection: ScopeSelection,
): boolean {
  if (selection === "all") return true;
  if (selection === "global") return item.scope.scope === "global";
  return (
    item.scope.scope === "project" && item.scope.root === selection.project
  );
}

/** What a surface has narrowed to. Handed to {@link filterItems} and to
 *  {@link missingUnder} as one object, so what the scan is narrowed by and
 *  what a row with no copy is judged against cannot drift apart. */
export interface ItemFilter {
  scope: ScopeSelection;
  harness?: string;
  tag?: Tag;
}

/** The narrowing that holds nothing back. A surface answering for the whole
 *  set states it with this rather than an empty filter of its own, so a
 *  facet {@link ItemFilter} gains cannot mean "everything" at one call site
 *  and something narrower at the next. */
export const EVERYWHERE: ItemFilter = { scope: "all" };

/** Narrowings that are true of one installation: where it is, which tool
 *  reads it, what its author said it is for. Which kind of package it is
 *  is not one of them — a tool stores a package under whatever kind it can
 *  load, so that question is answered of the group, in {@link groupsOfKind}. */
export function filterItems(
  items: ObservedItem[],
  filter: ItemFilter,
): ObservedItem[] {
  return items.filter((item) => {
    if (!scopeMatches(item, filter.scope)) return false;
    if (filter.harness && item.harness !== filter.harness) return false;
    if (filter.tag && !item.tags.includes(filter.tag)) return false;
    return true;
  });
}

/** Whether a typed search matches this package: its name, and the words
 *  its author wrote about it.
 *
 *  Asked of the group and not of each installation, because that is where
 *  a package's own words are. An installation is a registration in a
 *  tool's file or a copy of a tree; the summary belongs to the package the
 *  records say those are, and the same text is what the marketplace search
 *  reads — so one query cannot find a package in one list and miss it in
 *  the other. A blank query matches everything. */
export function groupMatches(group: ItemGroup, search: string): boolean {
  const needle = search.trim().toLowerCase();
  if (!needle) return true;
  return `${group.name} ${group.summary ?? ""}`.toLowerCase().includes(needle);
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
  /** What the author says this package does, or null where they wrote
   *  nothing reachable. Never a command, a URL or a path: a row with no
   *  summary shows none. */
  summary: string | null;
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

/** What tells this observation from another the scan saw under the same
 *  kind, name and tool — because it does see two: a tool reads both a
 *  shared root and one of its own, and one registry file holds every hook
 *  entry a tool runs.
 *
 *  Read off the scan, never rebuilt here. It is a canonical path in one
 *  spelling, which nothing above the filesystem can resolve, and core
 *  keys its provenance rows by the same value — a second derivation would
 *  be a second answer to one question, and the two would part company the
 *  moment a path went through a link or a platform spelled a separator
 *  its own way. Compared, never parsed. */
export const observedAt = (item: ObservedItem): string => item.at;

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
  summaryOf: SummaryOf = () => null,
): ItemGroup[] {
  const groups = new Map<string, ItemGroup>();
  for (const item of items) {
    const identity = packageOf(item);
    const key = identity
      ? packageKey(identity)
      : `observed:${item.kind}:${item.name}:${observedAt(item)}`;
    let group = groups.get(key);
    if (!group) {
      group = {
        key,
        package: identity,
        kind: identity?.kind ?? item.kind,
        name: identity?.name ?? item.name,
        summary: summaryOf(item),
        installations: [],
        harnesses: [],
        tags: [],
        shared: false,
        modifiedAt: null,
      };
      groups.set(key, group);
    }
    group.installations.push(item);
    // A package installed for several tools is read from whichever of its
    // copies has words: one tool storing a hook as a registration says
    // nothing about it while another's copy of the same package does.
    group.summary ??= summaryOf(item);
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
  return [...groups.values()].sort(byRowOrder);
}

/** One row's key for a package the records account for. Prefixed apart from
 *  an observation's: a package and a file nothing recorded are different
 *  claims about what a row is, and a package named for what some unrecorded
 *  file happens to be called must not join that file's row. */
export const packageKey = (ref: { kind: ItemKind; name: string }): string =>
  `package:${ref.kind}:${ref.name}`;

/** What the table shows — its type column, then its name — so rows of one
 *  type stay adjacent. Whether a row is a package the records account for
 *  is identity, not an order a reader can see, so the key only settles two
 *  rows the displayed columns cannot. */
const byRowOrder = (a: ItemGroup, b: ItemGroup): number =>
  a.kind.localeCompare(b.kind) ||
  a.name.localeCompare(b.name) ||
  a.key.localeCompare(b.key);

/** Whether a narrowing can admit a row for a package with no copy left.
 *
 *  Such a row carries no tool and no tags — there is no copy to carry them
 *  — so a narrowing by either is a question it cannot answer, and drawing
 *  the package under it would be a wrong answer rather than a missing one.
 *  Its place it does carry, so that narrowing it does answer.
 *
 *  Asked of the narrowing alone, because a surface has to know whether
 *  those rows belong in what it is drawing before it is given any:
 *  {@link missingUnder} is this same rule applied to rows in hand,
 *  {@link installedCountByKind} asks it without them, and the Library's
 *  empty state asks it to tell an emptiness the update read decides from
 *  one the scan decides alone. The one owner of that rule, because a
 *  caller spelling it out would be a second answer to the same question. */
export const admitsMissing = (filter: ItemFilter): boolean =>
  !filter.harness && !filter.tag;

/** The rows for packages with no copy left that a narrowing admits. */
export function missingUnder(
  missing: UpdateRow[],
  filter: ItemFilter,
): UpdateRow[] {
  if (!admitsMissing(filter)) return [];
  return missing.filter((row) => scopeMatches(row, filter.scope));
}

/** The grouped scan, plus a row for every recorded package it holds no
 *  observation of at all.
 *
 *  Deleting a package's rendering by hand leaves the record behind: the
 *  package is still installed, the update read plans the write that puts
 *  the files back, and the package's own page offers that as its repair.
 *  The scan has nothing left to observe, though, so grouping the scan alone
 *  drops the package off the list — while Home counts it among the packages
 *  missing files and links here. The rows saying a recorded rendering is
 *  gone are what stands it back up, and they are the rows Home reads: one
 *  source, not a second list beside the scan.
 *
 *  Only where no observation made a row for it. A package the scan sees in
 *  one place and not another already has one, and the place whose copy is
 *  gone is named on it by its own badge. */
export function withRecordedMissing(
  groups: ItemGroup[],
  missing: UpdateRow[],
): ItemGroup[] {
  const added = new Map<string, ItemGroup>();
  const seen = new Set(groups.map((group) => group.key));
  for (const row of missing) {
    const key = packageKey(row);
    if (seen.has(key) || added.has(key)) continue;
    added.set(key, {
      key,
      // A row the record establishes, which is what the update row is: it
      // was planned from a declaration, so its page, its versions and its
      // repair all address that declaration.
      package: { kind: row.kind, name: row.name },
      kind: row.kind,
      name: row.name,
      // The author's words reach a row through the copy on disk, and there
      // is no copy.
      summary: null,
      installations: [],
      harnesses: [],
      tags: [],
      shared: false,
      modifiedAt: null,
    });
  }
  if (added.size === 0) return groups;
  return [...groups, ...added.values()].sort(byRowOrder);
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
        at: group.installations[0] && observedAt(group.installations[0]),
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
 *  There is no grouping to search before that read answers — every row
 *  would read as unrecorded whatever it is — so a caller has the groups
 *  the read produced or has none, and this is only ever asked of the
 *  former. */
export function groupFor(
  groups: ItemGroup[],
  ref: PackageIdentityRef,
): ItemGroup | null {
  // A recorded link is answered by the identity alone; an unrecorded one
  // also has to name the file, because two rows can wear one kind and name
  // and neither is the other's stand-in.
  return (
    groups.find(
      (group) =>
        group.kind === ref.kind &&
        group.name === ref.name &&
        identityOf(group) === ref.identity &&
        (ref.identity === "recorded" || groupRef(group).at === ref.at),
    ) ?? null
  );
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
 *  what it hasn't.
 *
 *  Counts a package whose rendering is gone the way the Library's own list
 *  draws it, through {@link withRecordedMissing}: the record says it is
 *  installed here, so leaving it out would be a number the table its badge
 *  opens disagrees with.
 *
 *  Null where those rows are part of this place's total and no read may be
 *  counted over them — a figure taken then is definite over a set the
 *  failed check could not confirm. A narrowing {@link admitsMissing} refuses
 *  has a number whatever that read did, because no such row was ever in it. */
export function installedCountByKind(
  items: ObservedItem[],
  place: ItemPlace,
  packageOf: PackageOf,
  /** The rows saying a recorded rendering is gone, or null where nothing
   *  may be counted over them — `missing-files.ts::useCountableMissingRows`. */
  missing: UpdateRow[] | null,
): Map<ItemKind, number> | null {
  const filter: ItemFilter = {
    scope: place.scope ?? "all",
    harness: place.harness,
  };
  if (missing === null && admitsMissing(filter)) return null;
  const tally = new Map<ItemKind, number>();
  const here = filterItems(items, filter);
  const groups = withRecordedMissing(
    groupItems(here, packageOf),
    missingUnder(missing ?? [], filter),
  );
  for (const group of groups) {
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

/** What the author says this package does, as the scope a page is about
 *  has it.
 *
 *  A page names one scope, and its buttons work on that scope's copy, so
 *  the words beside the name are that scope's too. `ItemGroup.summary`
 *  folds every scope together — whichever installation the scan reached
 *  first — which on a project page can be another scope's line about a
 *  package that scope installed from a different source or version.
 *
 *  Within the scope it keeps the group's own rule, because one tool's
 *  copy can carry words where another's says nothing. Null where none of
 *  that scope's installations has any: a blank is this scope's answer,
 *  never a borrowed one. */
export function summaryAt(
  group: ItemGroup | null | undefined,
  scope: Scope | null | undefined,
  summaryOf: SummaryOf,
): string | null {
  if (!group || !scope) return null;
  for (const install of group.installations) {
    if (!sameScope(install.scope, scope)) continue;
    const summary = summaryOf(install);
    if (summary) return summary;
  }
  return null;
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

/** Every place one row stands for: where the scan saw a copy, and where a
 *  record says the copy is gone, each once.
 *
 *  A place the scan cannot see is still one of this row's — its record says
 *  so — and one set serves the Where cell, the badges naming a place, the
 *  single-place click and the provenance the From column reads. A row for a
 *  package no copy of which is left has only the second half, so asking the
 *  installations alone would leave it addressing nowhere. */
export function groupPlaces(group: ItemGroup, missingIn: Scope[]): Scope[] {
  return [...groupScopes(group), ...missingIn].filter(
    (scope, index, all) =>
      all.findIndex((other) => scopeKey(other) === scopeKey(scope)) === index,
  );
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

/** The places the Library offers to look: every project its rows stand in,
 * plus the one being looked at. A project can be picked before it holds
 * anything — from its card on Projects, or by emptying it while the table
 * is open — and a place with no pill would leave an empty table with
 * nothing on screen saying where it is looking.
 *
 * Asked of the places the rows carry rather than of the scan, because the
 * table draws rows the scan never saw: a project whose every package lost
 * its rendering still has rows here, and without its pill the reader
 * cannot narrow to the place those rows name. */
export function scopeChoices(
  places: Scope[],
  selection: ScopeSelection,
): string[] {
  const roots = new Set<string>();
  for (const place of places) {
    if (place.scope === "project") roots.add(place.root);
  }
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
export type GroupStatus = "active" | "off" | "broken" | "missing";

export function groupStatus(group: ItemGroup): GroupStatus {
  // Nothing observed anywhere: the record is what put this row on screen
  // and the files it names are gone. There is no copy to carry a switch or
  // a link, so every other reading below would be about no file at all.
  if (group.installations.length === 0) return "missing";
  const broken = group.installations.some(
    (i) => i.fileState.state === "symlink" && i.fileState.broken,
  );
  if (broken) return "broken";
  return group.installations.some((i) => i.enabled === false)
    ? "off"
    : "active";
}
