// One marketplace, however many places declare it. The Subscribed tab used
// to list a row per (place, marketplace), so a catalog subscribed
// everywhere appeared once per project with nothing saying the three rows
// were the same catalog. Grouping is the whole difference: the card is the
// marketplace, and the places it is subscribed in are a fact about it.
import type { MarketplaceRow } from "@/bindings";
import { scopeLabel } from "@/lib/derive";
import { scopeName } from "@/lib/labels";

export interface SubscribedMarketplace {
  /** Identity across places: the canonical repository where core resolved
   * one, else the local path, else the alias. Two places subscribing the
   * same repository under different aliases are still one marketplace. */
  key: string;
  /** What to call it — the alias the place a card opens uses. */
  name: string;
  /** The repository or folder behind it, for the card's second line. */
  where: string;
  /** Every place that declares it, personal first. */
  places: MarketplaceRow[];
  /** The subscription a card opens: an enabled place before a switched-off
   * one, personal before a project, so the page opens on the declaration
   * that is actually offering packages. */
  open: MarketplaceRow;
  /** Packages offered, from the first place whose catalog has been read —
   * null while none of them has been fetched. */
  packages: number | null;
}

const identity = (row: MarketplaceRow): string =>
  row.repoKey ?? row.path ?? row.name;

/** Personal leads, then projects in the order the overview listed them. */
const personalFirst = (a: MarketplaceRow, b: MarketplaceRow): number =>
  a.scope.scope === "global" ? -1 : b.scope.scope === "global" ? 1 : 0;

const offered = (row: MarketplaceRow): number | null =>
  row.counts
    ? Object.values(row.counts).reduce((sum, count) => sum + count, 0)
    : null;

/** Every subscribed marketplace, once, with the places holding it. */
export function groupByMarketplace(
  rows: MarketplaceRow[],
): SubscribedMarketplace[] {
  const groups = new Map<string, MarketplaceRow[]>();
  for (const row of rows) {
    const key = identity(row);
    const held = groups.get(key);
    if (held) held.push(row);
    else groups.set(key, [row]);
  }
  return [...groups.entries()]
    .map(([key, held]) => {
      const places = [...held].sort(personalFirst);
      // An enabled place outranks a switched-off one; among equals the
      // sort above has already put personal first.
      const open = places.find((row) => row.enabled) ?? places[0];
      return {
        key,
        name: open.name,
        where: open.repo ?? open.path ?? "",
        places,
        open,
        packages: places.map(offered).find((count) => count !== null) ?? null,
      };
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** The places a marketplace is subscribed in, named. */
export const placeNames = (group: SubscribedMarketplace): string[] =>
  group.places.map((row) => scopeName(row.scope));

/** Whether two rows describe the same place, for the Projects section's
 * keys — the same spelling `scopeLabel` gives everywhere else. */
export const placeKey = (row: MarketplaceRow): string =>
  `${scopeLabel(row.scope)}:${row.name}`;
