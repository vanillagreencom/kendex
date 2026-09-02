import type { PackageEntry } from "@/components/marketplaces/package-row";
import { kindLabel, packageDisplayName } from "@/lib/labels";

/** What the table is ordered by. Only columns whose value is in hand when
 *  the rows are drawn: a safety score arrives one row at a time after the
 *  table is on screen, and sorting on it would reshuffle the list under
 *  the reader's cursor. */
export type SortKey = "name" | "kind" | "updated";

export interface PackageSort {
  key: SortKey;
  /** Ascending is A-Z and oldest-first; the header toggles it. */
  ascending: boolean;
}

/** What the table opens on. */
export const BY_NAME: PackageSort = { key: "name", ascending: true };

const byName = (a: PackageEntry, b: PackageEntry): number =>
  packageDisplayName(a.row).localeCompare(packageDisplayName(b.row));

/** When a row's date is a moment, or NaN when it has none or the catalog
 *  wrote one nothing can read. A commit date is a catalog's bytes, and a
 *  repository can carry a commit whose timezone git prints and `Date.parse`
 *  rejects, so the two cases are one case here — as they are on the two
 *  surfaces that draw the date. */
const moment = (entry: PackageEntry): number =>
  entry.row.updatedAt ? Date.parse(entry.row.updatedAt) : Number.NaN;

/** A package with no readable date sorts last whichever way the column
 *  points: it is not older than everything, it is unknown, and burying it
 *  under the dated rows says that in both directions. Never subtracted
 *  while unknown — a NaN comparator makes the whole table's order
 *  implementation-defined, not just the row that carries it. */
const byUpdated = (a: PackageEntry, b: PackageEntry, ascending: boolean) => {
  const left = moment(a);
  const right = moment(b);
  if (Number.isNaN(left) && Number.isNaN(right)) return 0;
  if (Number.isNaN(left)) return 1;
  if (Number.isNaN(right)) return -1;
  // Comparing the parsed instants rather than the strings keeps two
  // catalogs written in different time zones honest.
  const order = left - right;
  return ascending ? order : -order;
};

/** The rows in the order the table draws them. Name breaks every tie, so
 *  the list never depends on the order the catalog happened to list its
 *  packages in. */
export function orderPackages(
  entries: PackageEntry[],
  sort: PackageSort,
): PackageEntry[] {
  const sorted = [...entries];
  sorted.sort((a, b) => {
    if (sort.key === "updated") {
      const order = byUpdated(a, b, sort.ascending);
      return order === 0 ? byName(a, b) : order;
    }
    if (sort.key === "kind") {
      const order = kindLabel(a.row.kind).localeCompare(kindLabel(b.row.kind));
      const directed = sort.ascending ? order : -order;
      return directed === 0 ? byName(a, b) : directed;
    }
    return sort.ascending ? byName(a, b) : -byName(a, b);
  });
  return sorted;
}
