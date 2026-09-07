import { useEffect, useMemo, useRef } from "react";
import type { ItemKind, Tag } from "@/bindings";
import { InstalledRow } from "@/components/library/installed-row";
import { InstalledSkeleton } from "@/components/library/installed-skeleton";
import { LibraryFilters } from "@/components/library/library-filters";
import { TableEmptyRow } from "@/components/library/table-empty";
import {
  applyLibraryView,
  useFilterHandoff,
} from "@/components/library/use-filter-handoff";
import {
  Table,
  TableBody,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { TAGS_ROW_LABEL } from "@/lib/copy";
import {
  filterItems,
  groupItems,
  groupScopes,
  installedCount,
  scopeChoices,
} from "@/lib/derive";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { isNarrowed, UNFILTERED } from "@/lib/library-handoff";
import { useLibraryStandings } from "@/lib/library-standings";
import { cn } from "@/lib/utils";
import { useEditorStore } from "@/stores/editor";
import {
  type FilterSelection,
  useLibraryViewStore,
} from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";
import {
  originFor,
  originLabel,
  useProvenanceStore,
} from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";

/** "Installed": everything on this machine, filterable. A row opens the
 *  package's own page; the filters and scroll position live in a store so
 *  coming back from that page lands exactly where the table was left. */
export function InstalledView() {
  const result = useScanStore((s) => s.result);
  const scope = useNavStore((s) => s.libraryScope);
  const setScope = useNavStore((s) => s.setLibraryScope);
  const goToMarketplaces = useNavStore((s) => s.goToMarketplaces);
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
  const loadProvenance = useProvenanceStore((s) => s.load);
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
  // Re-joined whenever a scan lands, so an install or unsubscribe made
  // elsewhere shows its changed origin without a manual refresh. Before
  // the first scan there are no rows to label, so there is nothing to join.
  useEffect(() => {
    if (!result) return;
    void loadProvenance();
  }, [loadProvenance, result]);

  const replaced = useFilterHandoff();

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
    () => (result ? groupItems(result.items) : []),
    [result],
  );
  // Read from those, never from the filtered set: a standing answers for
  // the package, so narrowing the table to one project must not change
  // which places a fork badge names.
  const { standingsFor, editedAnywhere } = useLibraryStandings(everywhere);
  const groups = useMemo(() => {
    if (!result) return [];
    const filtered = filterItems(result.items, {
      scope,
      kind: kind === "any" ? undefined : (kind as ItemKind),
      harness: harness === "any" ? undefined : harness,
      tag: tag === "any" ? undefined : (tag as Tag),
      search,
    });
    let grouped = groupItems(filtered);
    if (from !== "any") {
      grouped = grouped.filter(
        (group) =>
          originLabel(
            originFor(provenance, group.kind, group.name, groupScopes(group)),
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
    editedAnywhere,
  ]);

  // The count the filtered total is measured against: every row the table
  // could show, not the ones left after the current narrowing. Shared with
  // Home's Installed tile so the two can never disagree.
  const total = useMemo(() => installedCount(everywhere), [everywhere]);
  // The filter's vocabulary is what the join actually says, so a value
  // is never offered that no row carries.
  const fromOptions = useMemo(
    () => [...new Set(provenance.map((row) => originLabel(row.origin)))].sort(),
    [provenance],
  );
  // Nothing has been counted yet — distinct from "counted, found nothing".
  // Narrowed to edited packages, the count also waits on the updates read
  // that says which are edited.
  const scanning =
    result === null || (edited === "edited" && editedAnywhere === null);
  const hasAnyItems = (result?.items.length ?? 0) > 0;
  const filters: FilterSelection = { kind, harness, tag, from, edited };
  const filtered = isNarrowed({ filters, search, scope });

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
                  return (
                    <InstalledRow
                      key={group.key}
                      group={group}
                      origin={originFor(
                        provenance,
                        group.kind,
                        group.name,
                        groupScopes(group),
                      )}
                      forkedIn={standingsFor(group)
                        .filter((s) => s.why === "forked")
                        .map((s) => s.scope)}
                      onOpen={(scope) => {
                        const where = scope ?? primary?.scope;
                        if (!where) return;
                        goToPackage({
                          kind: group.kind,
                          name: group.name,
                          scope: where,
                        });
                      }}
                    />
                  );
                })}
                {scanning ? <InstalledSkeleton /> : null}
                {!scanning && groups.length === 0 ? (
                  <TableEmptyRow
                    hasAnyItems={hasAnyItems}
                    onClearFilters={clearFilters}
                    onBrowse={() => goToMarketplaces()}
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
