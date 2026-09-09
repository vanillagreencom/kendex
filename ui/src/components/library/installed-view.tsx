import { useEffect, useMemo, useRef } from "react";
import type { ItemKind, Scope, Tag } from "@/bindings";
import { InstalledRow } from "@/components/library/installed-row";
import { InstalledSkeleton } from "@/components/library/installed-skeleton";
import { LibraryFilters } from "@/components/library/library-filters";
import { TableEmptyRow } from "@/components/library/table-empty";
import {
  applyLibraryView,
  openLibraryAt,
  useFilterHandoff,
} from "@/components/library/use-filter-handoff";
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
  PACKAGES_CHECK_FAILED_TITLE,
  PACKAGES_UNCONFIRMED_TITLE,
  TAGS_ROW_LABEL,
  TRY_AGAIN_LABEL,
} from "@/lib/copy";
import {
  filterItems,
  groupItems,
  groupRef,
  groupScopes,
  groupsOfKind,
  installedCount,
  scopeChoices,
  selectionOf,
} from "@/lib/derive";
import { scopeNames } from "@/lib/labels";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { isNarrowed, UNFILTERED } from "@/lib/library-handoff";
import { useLibraryStandings } from "@/lib/library-standings";
import {
  usePackageIndex,
  usePackagesEverKnown,
  usePackagesKnown,
  usePackagesRead,
  useReloadPackages,
} from "@/lib/package-identity";
import { everyPlace, scopeKey } from "@/lib/scope";
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
  const packagesKnown = usePackagesKnown();
  // Whether any answer was ever kept, which is what tells a failure with
  // rows behind it from one with nothing.
  const packagesEverKnown = usePackagesEverKnown();
  // The read's own outcome, so a first read still on its way and one that
  // failed are not both drawn as waiting.
  const packagesRead = usePackagesRead();
  const reloadPackages = useReloadPackages();
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
  const projects = scopeChoices(result, scope);
  const scroller = useRef<HTMLDivElement | null>(null);
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

  // Every group the scan holds, before any narrowing.
  const everywhere = useMemo(
    () => (result && packageOf ? groupItems(result.items, packageOf) : []),
    [result, packageOf],
  );
  // Read from those, never from the filtered set: a standing answers for
  // the package, so narrowing the table to one project must not change
  // which places a fork badge names.
  const { standingsFor, editedAnywhere, outOfDateAnywhere } =
    useLibraryStandings(everywhere);
  const groups = useMemo(() => {
    // Nothing may be drawn until the read that says which observations are
    // one package has answered: grouped with an empty index every row is an
    // installation wearing a package's clothes, which is the duplication
    // this page exists to stop. With the read failed and nothing retained
    // the note above stands in their place instead.
    if (!result || !packageOf || packagesUnreadable) return [];
    const filtered = filterItems(result.items, {
      scope,
      harness: harness === "any" ? undefined : harness,
      tag: tag === "any" ? undefined : (tag as Tag),
      search,
    });
    let grouped = groupItems(filtered, packageOf);
    // Narrowed after grouping: the kind on screen is the package's, and a
    // tool that stores a hook as a rule would otherwise drop out of its
    // own filter and turn up under the kind its file happens to be.
    if (kind !== "any") grouped = groupsOfKind(grouped, kind as ItemKind);
    if (from !== "any") {
      grouped = grouped.filter(
        (group) =>
          originLabel(
            originFor(provenance, groupRef(group), groupScopes(group)),
          ) === from,
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
    scope,
    kind,
    harness,
    tag,
    from,
    edited,
    search,
    provenance,
    packageOf,
    packagesUnreadable,
    editedAnywhere,
  ]);

  // The count the filtered total is measured against: every row the table
  // could show, not the ones left after the current narrowing. Shared with
  // Home's Installed tile so the two can never disagree.
  // No number where the identity does not answer for this scan: a total
  // counted from an older answer is not the last-known total.
  const total = useMemo(
    () => (packageOf ? installedCount(everywhere) : null),
    [everywhere, packageOf],
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
  // total taken then would count installations. Narrowed to edited
  // packages, the count also waits on the updates read that says which are
  // edited.
  const scanning =
    packagesUnreadable === null &&
    !packagesStale &&
    (result === null ||
      !packageOf ||
      (edited === "edited" && editedAnywhere === null));
  const hasAnyItems = (result?.items.length ?? 0) > 0;
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
        {packagesRead.status === "failed" || packagesStale ? (
          <div className={cn("pb-4", WIDE_CONTENT_WIDTH)}>
            <StatusNote
              tone={packagesUnreadable ? "critical" : "warning"}
              title={
                packagesUnreadable
                  ? PACKAGES_CHECK_FAILED_TITLE
                  : PACKAGES_UNCONFIRMED_TITLE
              }
              action={
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => void reloadPackages()}
                >
                  {TRY_AGAIN_LABEL}
                </Button>
              }
            >
              {packagesRead.error}
            </StatusNote>
          </div>
        ) : null}
        <div className={cn("flex min-h-0 flex-1", WIDE_CONTENT_WIDTH)}>
          <div
            ref={scroller}
            className="min-w-0 flex-1 overflow-y-auto pr-2 [scrollbar-gutter:stable]"
          >
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Name</TableHead>
                  <TableHead>Type</TableHead>
                  <TableHead>{TAGS_ROW_LABEL}</TableHead>
                  <TableHead>Harnesses</TableHead>
                  <TableHead>Where</TableHead>
                  <TableHead>From</TableHead>
                  <TableHead className="text-right">Updated</TableHead>
                  <TableHead>Status</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {groups.map((group) => {
                  const primary = group.installations[0];
                  // The origin and the place that recorded it, read as one
                  // row: a marketplace source is an alias declared at a
                  // place, so pairing this row's alias with another place's
                  // scope can address a subscription that exists at neither.
                  const record = provenanceFor(
                    provenance,
                    groupRef(group),
                    groupScopes(group),
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
                      origin={origin}
                      forkedIn={standingsFor(group)
                        .filter((s) => s.why === "forked")
                        .map((s) => s.scope)}
                      outOfDate={outOfDateAnywhere?.(group) ?? false}
                      onOpen={(scope) => {
                        const where = scope ?? primary?.scope;
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
                {scanning ? <InstalledSkeleton /> : null}
                {!scanning &&
                !packagesUnreadable &&
                !packagesStale &&
                groups.length === 0 ? (
                  <TableEmptyRow
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
  );
}
