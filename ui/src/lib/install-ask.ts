// Turning rows a reader ticked into the guided install's own question.
//
// `marketplace_install` carries one subscription per call, and a table can
// list rows from several at once — the cross-marketplace Packages tab does
// exactly that. So a selection is folded into one group per subscription
// here, in one place, rather than by each table that offers a selection.
import type { AvailablePackage, Catalog } from "@/bindings";
import { offersInstall } from "@/lib/install-state";
import type { InstallGroup } from "@/stores/install-flow";
import { catalogKey } from "@/stores/marketplaces";

/** One row as a table holds it: which catalog offered it, and the package
 *  itself. */
export interface OfferedRow {
  catalog: Catalog;
  row: AvailablePackage;
  recordsUnreadable: boolean;
}

/** What a row is held by while it is ticked. Catalog and name both: two
 *  marketplaces can offer a package of the same kind and name, and they
 *  are two different installs. */
export const rowKey = (entry: OfferedRow): string =>
  `${catalogKey(entry.catalog)}:${entry.row.kind}:${entry.row.name}`;

/** Whether this row is one a reader can ask to install from here.
 *
 *  A row from a bare repository has no subscription to install from — it
 *  subscribes first, which is its own action — and a place whose lock
 *  could not be read has no known state to install against, which is the
 *  same answer the row's own Status cell gives. */
export const installableRow = (entry: OfferedRow): boolean =>
  entry.catalog.by === "subscription" &&
  !entry.recordsUnreadable &&
  offersInstall(entry.row.state);

/** These rows as install requests, one per subscription they came from.
 *  Rows that cannot be installed from here are left out rather than sent
 *  and refused. */
export function groupsFor(entries: OfferedRow[]): InstallGroup[] {
  const groups = new Map<string, InstallGroup>();
  for (const entry of entries) {
    if (!installableRow(entry) || entry.catalog.by !== "subscription") continue;
    const key = catalogKey(entry.catalog);
    const group = groups.get(key) ?? {
      source: entry.catalog.source,
      browsing: entry.catalog.scope,
      items: [],
      bundle: null,
    };
    group.items.push({ kind: entry.row.kind, name: entry.row.name });
    groups.set(key, group);
  }
  return [...groups.values()];
}

/** How many packages a set of groups installs. */
export const countIn = (groups: InstallGroup[]): number =>
  groups.reduce((total, group) => total + group.items.length, 0);

/** Every kind those groups declare, which is what decides the tools a
 *  single-place install may be offered. */
export const kindsIn = (groups: InstallGroup[]) => [
  ...new Set(groups.flatMap((group) => group.items.map((item) => item.kind))),
];
