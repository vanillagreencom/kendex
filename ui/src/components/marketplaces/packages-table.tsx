import { ArrowDown, ArrowUp } from "lucide-react";
import {
  type RefObject,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import type { Catalog, ProvenanceRow } from "@/bindings";
import {
  type PackageColumns,
  type PackageEntry,
  PackageRow,
} from "@/components/marketplaces/package-row";
import { useBrowsedRepo } from "@/components/marketplaces/repo-action";
import {
  Table,
  TableBody,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { SUBSCRIBE_TO_INSTALL_MEANS } from "@/lib/copy-marketplaces";
import { installedPlaces, placesKey } from "@/lib/installed-places";
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

/** A stable empty list, so a table that never reads the provenance join
 *  does not take a fresh array identity on every store read. */
const EMPTY: ProvenanceRow[] = [];

// What each column costs the table: the width its own header declares,
// which is the whole of it — these widths are border-box, so the cell's
// padding is already inside them. Name declares none, taking what is left;
// what it costs is the ceiling its cell carries, which is also the width
// at which a package name and the summary under it read in full.
//
// Below one of these sums the table still lays out, by squeezing every
// column toward its content: the tags stack a badge to a line and the row
// grows by a third. That is a squashed table rather than a cut one, but it
// is not a designed width, so a column goes rather than shrinks. Under the
// first sum there is nothing left to give, so the name's ceiling is the
// one that makes the four kept columns fit the narrowest window kendex
// opens beside the widest control the Status column carries.
//
// A ceiling caps what a column asks for, not what it may have: wherever
// the table has room to spare, the name takes it, so the ceiling shows
// only at a rung's own width.
const NAME_ROOM = 288; // `max-w-72` on the name cell
const KEPT_ROOM = NAME_ROOM + 112 + 80 + 128; // Name, Kind, Safety, Status
const OPTIONAL_ROOM: Record<keyof PackageColumns, number> = {
  marketplace: 160,
  places: 160,
  updated: 128,
  tags: 192,
};

/** The order the columns come back in as the table's room grows, and in
 *  reverse the order it gives them up. Where a package came from and where
 *  it landed are the first back because they say something no other column
 *  does; the tags are the last because the filter above the table asks the
 *  same question and the row's own page answers it in full. */
const RESTORE_ORDER: (keyof PackageColumns)[] = [
  "marketplace",
  "places",
  "updated",
  "tags",
];

const NONE: PackageColumns = {
  tags: false,
  marketplace: false,
  updated: false,
  places: false,
};

/** The columns `room` pixels can hold, out of the ones this table declares.
 *
 *  Name, Kind, Safety and Status are what a reader needs to tell one
 *  package from another and decide about it, so they stay at every width
 *  and the rest are spent against what is left over. A `room` of null is a
 *  width nothing has measured yet: the table opens on everything it
 *  declares and narrows once its own layout has answered. */
function afforded(
  room: number | null,
  declared: PackageColumns,
): PackageColumns {
  if (room === null) return declared;
  const shown = { ...NONE };
  let used = KEPT_ROOM;
  for (const column of RESTORE_ORDER) {
    if (!declared[column]) continue;
    used += OPTIONAL_ROOM[column];
    if (used > room) break;
    shown[column] = true;
  }
  return shown;
}

/** How wide the element the ref is on is, kept current as it changes.
 *  Null until a layout has answered: a zero width is an element nothing has
 *  laid out yet, not a table with no room to give a column. */
function useRoom(ref: RefObject<HTMLElement | null>): number | null {
  const [room, setRoom] = useState<number | null>(null);
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element) return;
    // Read once here, before the browser paints. A ResizeObserver reports
    // even its first observation on a later task, so left to it alone the
    // table draws every column once at whatever width it has — which at a
    // narrow one is the cut this fixes, on screen for a frame.
    const measured = (width: number) => setRoom(width > 0 ? width : null);
    measured(element.getBoundingClientRect().width);
    const observer = new ResizeObserver((entries) => {
      measured(entries[0]?.contentRect.width ?? 0);
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [ref]);
  return room;
}

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
  /** A column word, not a node: it is interpolated into the button's
   *  accessible name, where an element would read as "[object Object]". */
  children: string;
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
  subscription,
}: {
  entries: PackageEntry[];
  /** The cross-marketplace tab names each row's source; a single
   * marketplace's own page already says it once at the top. */
  showMarketplace: boolean;
  /** The one subscription this table is a page for, when it is a page for
   * one. Its presence is what draws the Installed in column, and it
   * carries the whole identity that column joins on — the cross-marketplace
   * list has no single subscription and so has no column. */
  subscription?: { catalog: Catalog; repo: string | null };
}) {
  // A bare repository's table is one catalog's; the cross-marketplace tab
  // only ever carries subscriptions. So what the repository offers is
  // decided once for the table, from the same identity and the same
  // `repoAction` the page header reads — a cell deciding for itself would
  // offer a Subscribe the engine refuses whenever a switched-off
  // subscription already declared the repository. The sentence is said
  // once, above the table, rather than as a tooltip on every row.
  const browsing = entries.find((entry) => entry.catalog.by === "repo");
  // `repo` is the subscription this table is a page for; the bare
  // repository it may be browsing instead takes the longer name.
  const browsedRepo =
    browsing?.catalog.by === "repo" ? browsing.catalog.repo : "";
  const rows = useMarketplacesStore((s) => s.rows);
  const read = useMarketplacesStore((s) => s.read);
  const summary = useMarketplacesStore(
    (s) => s.summaries[catalogKey({ by: "repo", repo: browsedRepo })] ?? null,
  );
  const { identity } = useBrowsedRepo(browsedRepo, summary);
  const { kind } = repoAction(rows, read, identity);
  // Only an undeclared repository can be subscribed from a row. A declared
  // one — switched off, or unreadable — is the header's Turn on or
  // Refresh, and a second control here would race it.
  const offerSubscribe = browsedRepo !== "" && kind === "subscribe";

  const [sort, setSort] = useState<PackageSort>(BY_NAME);
  const showPlaces = subscription !== undefined;
  // Only the page that shows the column reads the join, so the
  // cross-marketplace tab neither loads it nor re-renders on it.
  const provenance = useProvenanceStore((s) => (showPlaces ? s.rows : EMPTY));
  // One read, when the column appears. Keeping it current afterwards is not
  // this table's job, and `entries` is no proxy for it: it stands for
  // "something installed" only while the install lands in this page's own
  // scope — a redirected one writes its rows under the destination's key
  // and never touches these. `lib/rescan.ts` refreshes the join behind
  // every write, and the rows arrive here as a store read like any other.
  const reloadProvenance = useProvenanceStore((s) => s.reload);
  useEffect(() => {
    if (showPlaces) void reloadProvenance();
  }, [showPlaces, reloadProvenance]);

  // The room the table has is the room the page gives it, which no column
  // it draws can change: the wrapper fills the page's content column
  // whatever the table inside it does, so measuring it cannot chase itself.
  const roomRef = useRef<HTMLDivElement>(null);
  const room = useRoom(roomRef);
  const columns = useMemo(
    () =>
      afforded(room, {
        tags: true,
        updated: true,
        marketplace: showMarketplace,
        places: showPlaces,
      }),
    [room, showMarketplace, showPlaces],
  );
  // A column that is not on screen carries no control the reader can see or
  // undo, so an order it holds goes back to the one every width shows.
  const order = sort.key === "updated" && !columns.updated ? BY_NAME : sort;

  const ordered = useMemo(
    () => orderPackages(entries, order),
    [entries, order],
  );
  // One pass over the join for the whole table, rather than a full scan of
  // every installation on the machine per row, once per render.
  const places = useMemo(
    () =>
      subscription
        ? installedPlaces(provenance, subscription.catalog, subscription.repo)
        : new Map<string, string>(),
    [provenance, subscription],
  );

  return (
    <div ref={roomRef}>
      {offerSubscribe ? (
        <p className="mb-3 text-xs text-muted-foreground">
          {SUBSCRIBE_TO_INSTALL_MEANS}
        </p>
      ) : null}
      <Table>
        <TableHeader>
          <TableRow>
            <SortHead column="name" sort={order} onSort={setSort}>
              Name
            </SortHead>
            <SortHead
              column="kind"
              sort={order}
              onSort={setSort}
              className="w-28"
            >
              Kind
            </SortHead>
            {columns.tags ? <TableHead className="w-48">For</TableHead> : null}
            {columns.marketplace ? (
              <TableHead className="w-40">Marketplace</TableHead>
            ) : null}
            {columns.updated ? (
              <SortHead
                column="updated"
                sort={order}
                onSort={setSort}
                className="w-32"
              >
                Last updated
              </SortHead>
            ) : null}
            <TableHead className="w-20">Safety</TableHead>
            {columns.places ? (
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
              columns={columns}
              places={
                places.get(placesKey(entry.row.kind, entry.row.name)) ?? ""
              }
              offerSubscribe={offerSubscribe}
            />
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
