import { ArrowDown, ArrowUp } from "lucide-react";
import { type ReactNode, useEffect, useMemo, useState } from "react";
import {
  type PackageEntry,
  PackageRow,
} from "@/components/marketplaces/package-row";
import { useRepoKey } from "@/components/marketplaces/repo-action";
import {
  Table,
  TableBody,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { SUBSCRIBE_TO_INSTALL_MEANS } from "@/lib/copy-marketplaces";
import {
  BY_NAME,
  orderPackages,
  type PackageSort,
  type SortKey,
} from "@/lib/package-order";
import { cn } from "@/lib/utils";
import {
  catalogKey,
  repoAction,
  useMarketplacesStore,
} from "@/stores/marketplaces";
import { useProvenanceStore } from "@/stores/provenance";

export type { PackageEntry } from "@/components/marketplaces/package-row";

/** A column header that re-sorts the table. Clicking the column already
 *  sorted turns it around; clicking another takes it over, ascending. The
 *  arrow marks the sorted column, and the button's accessible name says
 *  which way it points so the arrow is never the only sign of it. */
function SortHead({
  column,
  sort,
  onSort,
  className,
  children,
}: {
  column: SortKey;
  sort: PackageSort;
  onSort: (sort: PackageSort) => void;
  className?: string;
  children: ReactNode;
}) {
  const active = sort.key === column;
  const next: PackageSort = active
    ? { key: column, ascending: !sort.ascending }
    : { key: column, ascending: true };
  const Arrow = sort.ascending ? ArrowUp : ArrowDown;
  return (
    <TableHead className={className}>
      <button
        type="button"
        className="flex cursor-pointer items-center gap-1 hover:text-foreground"
        aria-label={
          active
            ? `Sorted by ${children} ${sort.ascending ? "ascending" : "descending"}`
            : `Sort by ${children}`
        }
        onClick={() => onSort(next)}
      >
        {children}
        <Arrow className={cn("size-3", active ? "opacity-100" : "opacity-0")} />
      </button>
    </TableHead>
  );
}

/** The one table of offered packages — the Packages tab across every
 * subscription and a marketplace detail's own list are both this. */
export function PackagesTable({
  entries,
  showMarketplace,
  showPlaces = false,
}: {
  entries: PackageEntry[];
  /** The cross-marketplace tab names each row's source; a single
   * marketplace's own page already says it once at the top. */
  showMarketplace: boolean;
  /** Whether rows say where the package is installed from this catalog.
   * The answer comes from the Library's provenance join, which only a
   * marketplace's own page asks for. */
  showPlaces?: boolean;
}) {
  // A bare repository's table is one catalog's; the cross-marketplace tab
  // only ever carries subscriptions. So what the repository offers is
  // decided once for the table, from the same key and the same
  // `repoAction` the page header reads — a cell deciding for itself
  // offered a Subscribe the engine refuses whenever a switched-off
  // subscription already declared the repository. It also says the
  // sentence once: the tooltip it replaces was the same constant rendered
  // per row.
  const browsing = entries.find((entry) => entry.catalog.by === "repo");
  const repo = browsing?.catalog.by === "repo" ? browsing.catalog.repo : "";
  const rows = useMarketplacesStore((s) => s.rows);
  const read = useMarketplacesStore((s) => s.read);
  const summary = useMarketplacesStore(
    (s) => s.summaries[catalogKey({ by: "repo", repo })] ?? null,
  );
  const repoKey = useRepoKey(repo, summary);
  const { kind } = repoAction(rows, read, repoKey);
  // Only an undeclared repository can be subscribed from a row. A declared
  // one — switched off, or unreadable — is the header's Turn on or
  // Refresh, and a second control here would race it.
  const offerSubscribe = repo !== "" && kind === "subscribe";

  const [sort, setSort] = useState<PackageSort>(BY_NAME);
  const loadProvenance = useProvenanceStore((s) => s.load);
  useEffect(() => {
    if (showPlaces) void loadProvenance();
  }, [showPlaces, loadProvenance]);

  const ordered = useMemo(() => orderPackages(entries, sort), [entries, sort]);

  return (
    <>
      {offerSubscribe ? (
        <p className="mb-3 text-xs text-muted-foreground">
          {SUBSCRIBE_TO_INSTALL_MEANS}
        </p>
      ) : null}
      <Table>
        <TableHeader>
          <TableRow>
            <SortHead column="name" sort={sort} onSort={setSort}>
              Name
            </SortHead>
            <SortHead
              column="kind"
              sort={sort}
              onSort={setSort}
              className="w-28"
            >
              Kind
            </SortHead>
            <TableHead className="w-48">For</TableHead>
            {showMarketplace ? (
              <TableHead className="w-40">Marketplace</TableHead>
            ) : null}
            <SortHead
              column="updated"
              sort={sort}
              onSort={setSort}
              className="w-32"
            >
              Last updated
            </SortHead>
            <TableHead className="w-20">Safety</TableHead>
            {showPlaces ? (
              <TableHead className="w-40">Installed in</TableHead>
            ) : null}
            <TableHead className="w-32 text-right">Status</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {ordered.map((entry) => (
            <PackageRow
              key={`${catalogKey(entry.catalog)}:${entry.row.kind}:${entry.row.name}`}
              entry={entry}
              showMarketplace={showMarketplace}
              showPlaces={showPlaces}
              offerSubscribe={offerSubscribe}
            />
          ))}
        </TableBody>
      </Table>
    </>
  );
}
