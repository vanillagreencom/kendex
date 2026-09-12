import { useEffect, useMemo, useRef } from "react";
import type { ItemKind, Scope, Tag } from "@/bindings";
import {
  type InstalledColumns,
  InstalledRow,
} from "@/components/library/installed-row";
import { InstalledSkeleton } from "@/components/library/installed-skeleton";
import { LibraryFilters } from "@/components/library/library-filters";
import { TableEmptyRow } from "@/components/library/table-empty";
import {
  applyLibraryView,
  openLibraryAt,
  useFilterHandoff,
} from "@/components/library/use-filter-handoff";
import { PackagesNote } from "@/components/packages-note";
import { ChangesLine } from "@/components/project-changes/changes-line";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  CHECK_FOR_UPDATES_LABEL,
  TAGS_ROW_LABEL,
  UPDATES_ATTENTION_TITLE,
} from "@/lib/copy";
import {
  admitsMissing,
  EVERYWHERE,
  filterItems,
  groupItems,
  groupMatches,
  groupPlaces,
  groupRef,
  groupsOfKind,
  type ItemFilter,
  type ItemGroup,
  installedCount,
  missingUnder,
  scopeChoices,
  scopeMatches,
  selectionOf,
  withRecordedMissing,
} from "@/lib/derive";
import { scopeNames } from "@/lib/labels";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { isNarrowed, UNFILTERED } from "@/lib/library-handoff";
import { useLibraryStandings } from "@/lib/library-standings";
import { useCountableMissingRows, useMissingRows } from "@/lib/missing-files";
import {
  usePackageIndex,
  usePackagesEverKnown,
  usePackagesKnown,
  usePackagesRead,
  useSummaryIndex,
} from "@/lib/package-identity";
import { everyPlace, scopeKey } from "@/lib/scope";
import { afforded, type ColumnBudget, useRoom } from "@/lib/table-room";
import { workOut } from "@/lib/updates-read-state";
import { cn } from "@/lib/utils";
import { useEditorStore } from "@/stores/editor";
import {
  type FilterSelection,
  useLibraryViewStore,
} from "@/stores/library-view";
import { subscription } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import type { LibraryFilter } from "@/stores/nav-types";
import {
  originFor,
  originLabel,
  provenanceFor,
  useProvenanceStore,
} from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { projectsOf } from "@/stores/settings-projects";
import { useUpdatesStore } from "@/stores/updates";

/** Every optional column this table has to draw. Unlike the marketplace
 *  table, whose pages declare different sets, the Library's list is one
 *  page and always asks for all four. */
const DECLARED: InstalledColumns = {
  tags: true,
  harnesses: true,
  from: true,
  updated: true,
};

// What each column costs the table: the width its own header declares,
// which is the whole of it — these widths are border-box, so the cell's
// padding is already inside them. Name declares none, taking what is left;
// what it costs is the ceiling its cell carries, which is also the width
// at which a package name and the summary under it read in full.
//
// Below the kept sum the table still lays out, by squeezing every column
// toward its content: the harness chips stack to a second line and the row
// grows. That is a squashed table rather than a cut one, but it is not a
// designed width, so a column goes rather than shrinks. The kept sum is
// sized against the room a 900px window leaves this table — the narrowest
// window kendex opens, less the sidebar and its border, the page gutters
// `PAGE_GUTTER` draws at that viewport, the scroller's `pr-2`, and the
// lane `[scrollbar-gutter:stable]` reserves beside it. That last term is
// the engine's, zero where scrollbars overlay and about 15px where they
// take their own column, so the room is 603 or 588 rather than one number.
// The kept sum sits between them, which costs nothing: only the name
// column carries a ceiling, and a ceiling has no floor under it, so at the
// tighter figure the name gives back the few pixels and the other three
// are drawn as declared. No column changes hands across that range either
// — the next rung up is 752, where the harnesses come back.
const NAME_ROOM = 288; // `max-w-72` on the name cell

/** How many columns are drawn at every width. Name, Type, Where and Status
 *  are what a reader needs to tell one row from another and decide about
 *  it: what the package is called, what kind of thing it is, which place
 *  holds it — the list spans every place on the machine, so two rows of one
 *  package are told apart by nothing else — and whether it is working. */
const KEPT_COLUMNS = 4;

/** What the kept columns cost, and what each of the rest costs against
 *  what is left over.
 *
 *  The tools a package is installed for are the first back, because the row
 *  says that nowhere else. The tags are the last, because the filter bar
 *  above the table asks the same question. Nothing that goes is out of
 *  reach: the harness, source and tag facets on that filter bar reach three
 *  of them, and the package's own page carries all four — the date and the
 *  shared-files badge, which the harness cell draws beside its chips, rest
 *  on that page alone, since the bar's Files facet asks what a person
 *  edited on disk rather than when the package last changed. */
const BUDGET: ColumnBudget<keyof InstalledColumns> = {
  kept: NAME_ROOM + 112 + 112 + 80,
  optional: { harnesses: 160, from: 128, updated: 112, tags: 160 },
  order: ["harnesses", "from", "updated", "tags"],
};

/** "Installed": everything on this machine, filterable. A row opens the
 *  package's own page; the filters and scroll position live in a store so
 *  coming back from that page lands exactly where the table was left. */
export function InstalledView() {
  const result = useScanStore((s) => s.result);
  const scope = useNavStore((s) => s.libraryScope);
  const setScope = useNavStore((s) => s.setLibraryScope);
  const goToMarketplaces = useNavStore((s) => s.goToMarketplaces);
  const goToMarketplace = useNavStore((s) => s.goToMarketplace);
  const goToPackage = useNavStore((s) => s.goToPackage);
  const {
    kind,
    harness,
    tag,
    from,
    edited,
    setKind,
    setHarness,
    setTag,
    setFrom,
    setEdited,
    setScrollTop,
  } = useLibraryViewStore();

  const provenance = useProvenanceStore((s) => s.rows);
  // Which observations are one package, from the one join that says so.
  const packageOf = usePackageIndex();
  // The words each package's author wrote, from the same join, so the row,
  // its preview and its page cannot describe one package differently.
  const summaryOf = useSummaryIndex();
  const packagesKnown = usePackagesKnown();
  // Whether any answer was ever kept, which is what tells a failure with
  // rows behind it from one with nothing.
  const packagesEverKnown = usePackagesEverKnown();
  // The read's own outcome, so a first read still on its way and one that
  // failed are not both drawn as waiting.
  const packagesRead = usePackagesRead();
  // The join failed and left nothing behind: there is no row to draw and no
  // wait to draw either, so the table says what happened and offers the
  // read again. A failure after one landed keeps its rows, headed below as
  // last-known.
  const packagesUnreadable =
    !packagesEverKnown && packagesRead.status === "failed"
      ? packagesRead
      : null;
  // A read that failed has settled: it is not coming back on its own, so
  // the table says so rather than holding a skeleton for ever. It does NOT
  // draw rows from an answer about another scan — grouping the scan on
  // screen against an older index is the duplication this page exists to
  // remove, and calling the result "the last kendex could check" would be
  // describing a state that never existed.
  const packagesStale = !packagesKnown && packagesRead.status === "failed";
  // Kept in nav rather than here so leaving for a package page and coming
  // back lands on the same narrowed table.
  const search = useNavStore((s) => s.search);
  const setSearch = useNavStore((s) => s.setSearch);
  const scroller = useRef<HTMLDivElement | null>(null);
  const roomRef = useRef<HTMLDivElement>(null);
  const room = useRoom(roomRef);
  const columns = useMemo(() => afforded(room, DECLARED, BUDGET), [room]);
  // What the empty row has to span, and the width the placeholder rows are
  // drawn at: the columns on screen, not the ones the table could draw.
  const drawn = KEPT_COLUMNS + Object.values(columns).filter(Boolean).length;
  // Every scope's manifest, so a row can say whether you have changed the
  // package wherever it is installed — not only in the scope last edited.
  const loadAll = useEditorStore((s) => s.loadAll);
  useEffect(() => {
    void loadAll();
  }, [loadAll]);
  const replaced = useFilterHandoff();

  // A chip or a place on a row asks for the same view a link from another
  // page asks for, so it goes through the same owner — which applies it in
  // place here rather than leaving a handoff nothing on this page reads.
  // The rows it lands on are a different set from the ones scrolled past,
  // so the table starts at the top, exactly as an arriving link does.
  const narrowTo = (handoff: LibraryFilter) => {
    openLibraryAt(handoff);
    if (scroller.current) scroller.current.scrollTop = 0;
  };

  // Pick up where the table was last scrolled to, and record it again on the
  // way out — unless a link replaced the list, in which case that offset
  // belongs to the list the link replaced.
  useEffect(() => {
    const node = scroller.current;
    if (!node) return;
    node.scrollTop = replaced ? 0 : useLibraryViewStore.getState().scrollTop;
    return () => setScrollTop(node.scrollTop);
  }, [replaced, setScrollTop]);

  // The packages whose rendering a record says is gone — the rows Home
  // counts. A package the scan cannot see at all has no observation to
  // group, so these are what put its row on this list.
  const missingRows = useMissingRows();
  // The same rows where a number may be taken over them. A row on this
  // table is a last-known fact about one package and stands whatever the
  // last check did; the total under the filters is a claim about the whole
  // set, and the check that failed was asked to confirm exactly that set.
  const countableMissing = useCountableMissingRows();
  // The update read's own outcome, and the way to ask again. A page that
  // withholds a figure on this read has to say so and offer the check,
  // which is what `ui/AGENTS.md` requires of every failed read.
  const updatesRead = useUpdatesStore((s) => s.read);
  const checkUpdates = useUpdatesStore((s) => s.check);
  // A check builds its report once and a write reads off those rows, so
  // neither may start while the other is out. The store's own rule.
  const updatesWorking = useUpdatesStore(workOut);
  // Every group the table holds, before any narrowing.
  const everywhere = useMemo(
    () =>
      result && packageOf
        ? withRecordedMissing(
            groupItems(result.items, packageOf, summaryOf),
            missingRows ?? [],
          )
        : [],
    [result, packageOf, summaryOf, missingRows],
  );
  // Read from those, never from the filtered set: a standing answers for
  // the package, so narrowing the table to one project must not change
  // which places a fork badge names.
  const { standingsFor, editedAnywhere, outOfDateAnywhere, missingIn } =
    useLibraryStandings(everywhere);
  // One narrowing object for every half of this list: what the scan is
  // filtered by, which packages with no copy left it admits, and — below
  // the table — whether an emptiness under it is the update read's to
  // decide at all.
  const narrowing: ItemFilter = useMemo(
    () => ({
      scope,
      harness: harness === "any" ? undefined : harness,
      tag: tag === "any" ? undefined : (tag as Tag),
    }),
    [scope, harness, tag],
  );

  // The places a row stands in as the table's own narrowing has them,
  // falling back to all of them where the location facet admits none.
  //
  // Narrowed by every facet, not the location alone: the places where the
  // copy is gone come through the same `missingUnder` the list above builds
  // its rows with, so a tool or a tag — which a row with no copy left
  // carries neither of — leaves the row answering from what the scan saw.
  // Everything that has to answer for the table on screen reads this: the
  // row's Where cell and badges, its click, and the record its From column
  // names and filters on, since a marketplace alias is declared at a place
  // and another place's alias can address a subscription that exists at
  // neither.
  const here = useMemo(
    () => (group: ItemGroup) => {
      const all = groupPlaces(group, missingIn?.(group, narrowing) ?? []);
      const admitted = all.filter((one) =>
        scopeMatches({ scope: one }, narrowing.scope),
      );
      return admitted.length > 0 ? admitted : all;
    },
    [missingIn, narrowing],
  );

  const groups = useMemo(() => {
    // Nothing may be drawn until the read that says which observations are
    // one package has answered: grouped with an empty index every row is an
    // installation wearing a package's clothes, which is the duplication
    // this page exists to stop. With the read failed and nothing retained
    // the note above stands in their place instead.
    if (!result || !packageOf || packagesUnreadable) return [];
    const filtered = filterItems(result.items, narrowing);
    // Searched after grouping, because what a search reads is the
    // package's name and its author's words, and both belong to the
    // package rather than to any one of its installations.
    let grouped = withRecordedMissing(
      groupItems(filtered, packageOf, summaryOf),
      missingUnder(missingRows ?? [], narrowing),
    ).filter((group) => groupMatches(group, search));
    // Narrowed after grouping: the kind on screen is the package's, and a
    // tool that stores a hook as a rule would otherwise drop out of its
    // own filter and turn up under the kind its file happens to be.
    if (kind !== "any") grouped = groupsOfKind(grouped, kind as ItemKind);
    if (from !== "any") {
      grouped = grouped.filter(
        (group) =>
          originLabel(originFor(provenance, groupRef(group), here(group))) ===
          from,
      );
    }
    // The edited narrowing reads the same per-place fact Home's edited
    // row counts, so the row's link lands on exactly those packages.
    // Before the updates read lands the fact is unknown, and the table
    // shows its skeleton rather than an empty list claiming none.
    if (edited === "edited") {
      grouped = editedAnywhere ? grouped.filter(editedAnywhere) : [];
    }
    return grouped;
  }, [
    result,
    narrowing,
    kind,
    from,
    edited,
    search,
    provenance,
    packageOf,
    summaryOf,
    packagesUnreadable,
    editedAnywhere,
    here,
    missingRows,
  ]);

  // Every place the table's rows stand in, read off those rows rather than
  // off the scan: a project whose every package lost its rendering still
  // has rows here, and with no pill for it the reader cannot narrow to the
  // place those rows name.
  const projects = useMemo(
    () =>
      scopeChoices(
        // Every place, narrowed by nothing: a pill is how a reader reaches
        // a narrowing, so offering only the places the current one admits
        // would leave a facet no way out of itself.
        everywhere.flatMap((group) =>
          groupPlaces(group, missingIn?.(group, EVERYWHERE) ?? []),
        ),
        scope,
      ),
    [everywhere, missingIn, scope],
  );

  // The count the filtered total is measured against: every row the table
  // could show, not the ones left after the current narrowing. Shared with
  // Home's Installed tile so the two can never disagree.
  //
  // No number while either read that decides the row set is silent. A
  // total counted from an older identity answer is not the last-known
  // total; and a package can be installed with nothing observed of it, so
  // one counted over update rows nothing confirmed is definite about a set
  // the failed check was asked about and could not answer for.
  const total = useMemo(
    () => (packageOf && countableMissing ? installedCount(everywhere) : null),
    [everywhere, packageOf, countableMissing],
  );
  // The filter's vocabulary is what the join actually says, so a value
  // is never offered that no row carries.
  const fromOptions = useMemo(
    () => [...new Set(provenance.map((row) => originLabel(row.origin)))].sort(),
    [provenance],
  );
  // Nothing has been counted yet — distinct from "counted, found nothing"
  // and from "counting failed". The join is waited on with the scan: until
  // it answers nothing knows which observations are one package, and a
  // total taken then would count installations. The first update read is
  // waited on too: a package with no copy left is in this total and those
  // rows are the only thing that says so, so a total taken before they
  // land is short by exactly them. Narrowed to edited packages, the count
  // also waits on that read for which packages are edited.
  //
  // Only the FIRST update read. A later check leaves `read` landed and
  // raises `checking` instead, so asking again never pulls the counter
  // back to a skeleton over rows that are still on screen.
  const scanning =
    packagesUnreadable === null &&
    !packagesStale &&
    (result === null ||
      !packageOf ||
      updatesRead.status === "pending" ||
      (edited === "edited" && editedAnywhere === null));
  // Asked of the rows the table has, not of the scan: the empty state
  // picks its words from this, and a machine whose only packages lost
  // their renderings holds rows the scan cannot count.
  const hasAnyItems = everywhere.length > 0;
  const filters: FilterSelection = { kind, harness, tag, from, edited };
  const filtered = isNarrowed({ filters, search, scope });
  // The one place this table is narrowed to, when the place is the whole
  // narrowing. Narrowed by a kind or a search on top, an empty table is
  // what those are hiding rather than an empty place, so the way out is to
  // clear them — and the empty state says so instead.
  const onePlace: Scope | null =
    scope === "all" || isNarrowed({ filters, search, scope: "all" })
      ? null
      : scope === "global"
        ? { scope: "global" }
        : { scope: "project", root: scope.project };
  // Named the way every other surface names it: two projects can end in
  // the same folder, and the button this label is on is a promise about
  // which one the install lands in.
  const places = everyPlace(useSettingsStore(projectsOf));
  const placeName =
    onePlace === null
      ? null
      : (scopeNames(places)[
          places.findIndex((one) => scopeKey(one) === scopeKey(onePlace))
        ] ?? null);

  const clearFilters = () => applyLibraryView(UNFILTERED);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <LibraryFilters
        search={search}
        onSearchChange={setSearch}
        kind={kind}
        onKindChange={setKind}
        harness={harness}
        onHarnessChange={setHarness}
        tag={tag}
        onTagChange={setTag}
        from={from}
        onFromChange={setFrom}
        fromOptions={fromOptions}
        edited={edited}
        onEditedChange={setEdited}
        scope={scope}
        onScopeChange={setScope}
        projects={projects}
        shown={groups.length}
        total={total}
        counting={scanning}
        filtered={filtered}
        onClear={clearFilters}
      />
      <div className={cn("flex min-h-0 flex-1 flex-col pt-6", PAGE_GUTTER)}>
        {/* The read that says which installations are one package failed.
            With nothing kept from an earlier answer there is no table to
            draw, so the page says so and offers the read again rather than
            holding a skeleton nothing will ever replace. With rows kept,
            they stay — headed as the last answer that landed, not as
            confirmed ones. Neither reading turns unavailable evidence into
            a claim that a package is managed or that it is not. */}
        {packagesRead.status === "failed" ? (
          <div className={cn("pb-4", WIDE_CONTENT_WIDTH)}>
            <PackagesNote />
          </div>
        ) : null}
        {/* The other read a total stands on. A package with no copy left is
            on this machine and these rows are the only thing that says so,
            so a check that failed takes the total away — and a figure
            withheld without its reason is a dash nobody can act on. The
            rows the table draws are last-known rather than absent, which is
            the warning tone; the check is offered again here, because this
            is where the reader is looking. Its own words, from the read
            that failed. */}
        {updatesRead.status === "failed" ? (
          <div className={cn("pb-4", WIDE_CONTENT_WIDTH)}>
            <StatusNote
              tone="warning"
              title={UPDATES_ATTENTION_TITLE}
              action={
                <Button
                  size="sm"
                  variant="outline"
                  disabled={updatesWorking}
                  onClick={() => void checkUpdates()}
                >
                  {CHECK_FOR_UPDATES_LABEL}
                </Button>
              }
            >
              {updatesRead.error}
            </StatusNote>
          </div>
        ) : null}
        {/* The project's own view of what kendex has written here and not
            committed — the same line the project's card carries, from the
            same read, so a reader who came in from the card finds it where
            they left it. Only where the table IS one project: on the
            machine-wide list it would be a line about a project the reader
            has not named. */}
        {onePlace?.scope === "project" ? (
          <div className={cn("pb-4", WIDE_CONTENT_WIDTH)}>
            <ChangesLine root={onePlace.root} />
          </div>
        ) : null}
        <div className={cn("flex min-h-0 flex-1", WIDE_CONTENT_WIDTH)}>
          <div
            ref={scroller}
            className="min-w-0 flex-1 overflow-y-auto pr-2 [scrollbar-gutter:stable]"
          >
            {/* The room the table has is the room the page gives it, which
                no column it draws can change: this block fills the
                scroller's content box whatever the table inside it does,
                so measuring it cannot chase itself. */}
            <div ref={roomRef}>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Name</TableHead>
                    <TableHead className="w-28">Type</TableHead>
                    {columns.tags ? (
                      <TableHead className="w-40">{TAGS_ROW_LABEL}</TableHead>
                    ) : null}
                    {columns.harnesses ? (
                      <TableHead className="w-40">Harnesses</TableHead>
                    ) : null}
                    <TableHead className="w-28">Where</TableHead>
                    {columns.from ? (
                      <TableHead className="w-32">From</TableHead>
                    ) : null}
                    {columns.updated ? (
                      <TableHead className="w-28 text-right">Updated</TableHead>
                    ) : null}
                    <TableHead className="w-20">Status</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {groups.map((group) => {
                    // The origin and the place that recorded it, read as one
                    // row: a marketplace source is an alias declared at a
                    // place, so pairing this row's alias with another place's
                    // scope can address a subscription that exists at neither.
                    const record = provenanceFor(
                      provenance,
                      groupRef(group),
                      here(group),
                    );
                    const origin = record?.origin ?? null;
                    // The pair a marketplace is addressed by, taken from the
                    // one row: the alias, and the place that declared it.
                    const from =
                      record && record.origin.origin === "marketplace"
                        ? { scope: record.scope, source: record.origin.source }
                        : null;
                    return (
                      <InstalledRow
                        key={group.key}
                        group={group}
                        columns={columns}
                        origin={origin}
                        forkedIn={standingsFor(group)
                          .filter((s) => s.why === "forked")
                          .map((s) => s.scope)}
                        outOfDate={outOfDateAnywhere?.(group) ?? false}
                        missingIn={missingIn?.(group, narrowing) ?? []}
                        onOpen={(scope) => {
                          const where = scope ?? here(group)[0];
                          if (!where) return;
                          goToPackage({
                            ...groupRef(group),
                            scope: where,
                          });
                        }}
                        onOpenHarness={(harness) => narrowTo({ harness })}
                        onOpenPlace={(where) =>
                          narrowTo({ scope: selectionOf(where) })
                        }
                        // Only a marketplace has a page to open: a package
                        // the reader wrote, and one nothing manages, name
                        // none. The subscription is addressed with the same
                        // row's own scope, which is the place that declared
                        // the alias.
                        onOpenFrom={
                          from
                            ? () =>
                                goToMarketplace(
                                  subscription(from.scope, from.source),
                                )
                            : undefined
                        }
                      />
                    );
                  })}
                  {scanning ? <InstalledSkeleton columns={columns} /> : null}
                  {/* Not while no number may be taken over the missing
                      rows: which of the two emptinesses this is — nothing
                      installed, or nothing matching — is as definite a
                      claim as the total is, and a re-check that failed was
                      asked about the very rows that would have made the
                      table non-empty. Suppressed the way a packages read
                      that cannot answer suppresses it.

                      Only where the narrowing could hold such a row at
                      all. A tool or a tag is a question no package with no
                      copy left can answer, so under one of those the
                      emptiness is the scan's alone and the update read
                      decides nothing about it — withholding the wording
                      there leaves a reader a blank table with no way out
                      of the filter hiding it. `admitsMissing` is the one
                      owner of that rule; the list above asks it through
                      `missingUnder` over the same narrowing. */}
                  {!scanning &&
                  !packagesUnreadable &&
                  !packagesStale &&
                  (countableMissing !== null || !admitsMissing(narrowing)) &&
                  groups.length === 0 ? (
                    <TableEmptyRow
                      span={drawn}
                      hasAnyItems={hasAnyItems}
                      place={placeName}
                      onClearFilters={clearFilters}
                      onBrowse={() => goToMarketplaces()}
                      // Browsing on this place's behalf, so the guided
                      // install opens on it rather than asking again where
                      // the reader already said.
                      onAddPackages={() =>
                        onePlace && goToMarketplaces("packages", onePlace)
                      }
                    />
                  ) : null}
                </TableBody>
              </Table>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
