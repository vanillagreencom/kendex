import { useEffect, useMemo, useRef } from "react";
import type { ItemKind, Tag } from "@/bindings";
import { InstalledTable } from "@/components/library/installed-table";
import { LibraryFilters } from "@/components/library/library-filters";
import { NotManagedPanel } from "@/components/library/not-managed";
import {
  applyLibraryView,
  useFilterHandoff,
} from "@/components/library/use-filter-handoff";
import {
  filterItems,
  groupItems,
  groupScopes,
  projectScopes,
} from "@/lib/derive";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { isNarrowed, UNFILTERED } from "@/lib/library-handoff";
import { cn } from "@/lib/utils";
import {
  type FilterSelection,
  useLibraryViewStore,
} from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";
import {
  indexOrigins,
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
  const {
    kind,
    harness,
    tag,
    from,
    setKind,
    setHarness,
    setTag,
    setFrom,
    setScrollTop,
  } = useLibraryViewStore();
  const provenance = useProvenanceStore((s) => s.rows);
  const loadProvenance = useProvenanceStore((s) => s.load);
  // Kept in nav rather than here so leaving for a package page and coming
  // back lands on the same narrowed table.
  const search = useNavStore((s) => s.search);
  const setSearch = useNavStore((s) => s.setSearch);
  const projects = result ? projectScopes(result) : [];
  const scroller = useRef<HTMLDivElement | null>(null);
  // Re-joined whenever a scan lands, so an install or unsubscribe made
  // elsewhere shows its new origin without a manual refresh. Before the
  // first scan there are no rows to label, so there is nothing to join.
  useEffect(() => {
    if (!result) return;
    void loadProvenance();
  }, [loadProvenance, result]);
  const replaced = useFilterHandoff();

  // Pick up where the table was last scrolled to, and record it again on the
  // way out — unless a link replaced the list, in which case that offset
  // belongs to something no longer on screen.
  useEffect(() => {
    const node = scroller.current;
    if (!node) return;
    node.scrollTop = replaced ? 0 : useLibraryViewStore.getState().scrollTop;
    return () => setScrollTop(node.scrollTop);
  }, [replaced, setScrollTop]);

  // Keyed once per read, then asked per group: scanning every provenance
  // row for every group is the whole cost of this join at a few hundred
  // packages.
  const origins = useMemo(() => indexOrigins(provenance), [provenance]);
  const groups = useMemo(() => {
    if (!result) return [];
    const filtered = filterItems(result.items, {
      scope,
      kind: kind === "any" ? undefined : (kind as ItemKind),
      harness: harness === "any" ? undefined : harness,
      tag: tag === "any" ? undefined : (tag as Tag),
      search,
    });
    const grouped = groupItems(filtered);
    if (from === "any") return grouped;
    return grouped.filter(
      (group) =>
        originLabel(
          originFor(origins, group.kind, group.name, groupScopes(group)),
        ) === from,
    );
  }, [result, scope, kind, harness, tag, from, search, origins]);

  // The count the filtered total is measured against: every row the table
  // could show, not the ones left after the current narrowing.
  const total = useMemo(
    () => (result ? groupItems(result.items).length : 0),
    [result],
  );
  // The filter's vocabulary is what the join actually says, so a value
  // is never offered that no row carries.
  const fromOptions = useMemo(
    () => [...new Set(provenance.map((row) => originLabel(row.origin)))].sort(),
    [provenance],
  );
  // Nothing has been counted yet — distinct from "counted, found nothing".
  const scanning = result === null;
  const hasAnyItems = (result?.items.length ?? 0) > 0;
  const filters: FilterSelection = { kind, harness, tag, from };
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
            <NotManagedPanel />
            <InstalledTable
              groups={groups}
              origins={origins}
              scanning={scanning}
              hasAnyItems={hasAnyItems}
              onClearFilters={clearFilters}
              onBrowse={() => goToMarketplaces()}
            />
          </div>
        </div>
      </div>
    </div>
  );
}
