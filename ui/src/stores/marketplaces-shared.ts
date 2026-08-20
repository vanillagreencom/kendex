// The cache vocabulary the marketplaces store and its readers share: the
// collision-free subscription key, and the invalidation every catalog-moving
// mutation runs.
import type { Catalog, MarketplaceRow, Scope } from "@/bindings";
import { useAuditStore } from "./audit";
import { resetPreinstallSafety } from "./preinstall-safety";
import { useScanStore } from "./scan";

/** One subscription's cache key: where it lives plus its alias, encoded so
 * a root or alias containing the delimiter can never collide with another
 * subscription's key. */
export const marketKey = (scope: Scope, source: string): string =>
  JSON.stringify([scope.scope === "global" ? null : scope.root, source]);

/** Any catalog's cache key — a subscription's is [marketKey], so what a
 * subscription's rows cached stays found when a page addresses it. */
export const catalogKey = (catalog: Catalog): string =>
  catalog.by === "subscription"
    ? marketKey(catalog.scope, catalog.source)
    : JSON.stringify(["repo", catalog.repo]);

/** The repositories the live subscription list holds, by canonical key —
 * what a Community row's Subscribed marker reads, so it flips the moment
 * a subscription lands or goes, wherever that happened. */
export const subscribedKeys = (rows: MarketplaceRow[]): Set<string> =>
  new Set(rows.flatMap((row) => (row.repoKey ? [row.repoKey] : [])));

/** Whether a [catalogKey] names a repository rather than a subscription. */
export const isRepoKey = (key: string): boolean =>
  key.startsWith(JSON.stringify(["repo", ""]).slice(0, -3));

/** One curated set's cache and error key, in its own namespace so a set
 * named like a read ("packages") can never land on that read's key. */
export const bundleKey = (catalog: Catalog, name: string): string =>
  `${readErrorKey(catalogKey(catalog), "bundle")}::${name}`;

export const subscription = (scope: Scope, source: string): Catalog => ({
  by: "subscription",
  scope,
  source,
});

/** What a catalog is called in a title or breadcrumb. */
export const catalogLabel = (catalog: Catalog | undefined): string | null =>
  !catalog
    ? null
    : catalog.by === "subscription"
      ? catalog.source
      : catalog.repo;

/** What lands after any mutation: the tables everywhere else stay current. */
export async function refreshDownstream() {
  await useScanStore.getState().refresh();
  await useAuditStore.getState().refresh();
}

export function without<T>(
  map: Record<string, T>,
  key: string,
): Record<string, T> {
  const { [key]: _, ...rest } = map;
  return rest;
}

/** A mutation that can change what any catalog offers empties every derived
 * cache — the pages re-read, and pre-install scores are re-asked, so nothing
 * keeps describing the commit before the change. A repository's summary is
 * kept: it only says which subscription the page carries on as, and
 * dropping it would blank an open page behind a second fetch. */
export function dropCatalogCaches(set: (partial: object) => void) {
  set({ packages: {}, bundles: {}, about: {}, readErrors: {} });
  resetPreinstallSafety();
}

/** The error key one cached read fails under, kept apart from the other
 * reads of the same catalog so a later success elsewhere never erases it. */
export const readErrorKey = (key: string, read: string): string =>
  `${key}::${read}`;

/** A tree or skills.sh URL was pointing at one package; land on it so
 * Install is the next click, with its safety verdict in view. */
export async function openLead(scope: Scope, source: string, lead: string) {
  const { useNavStore } = await import("./nav");
  useNavStore.getState().goToAvailablePackage({
    catalog: subscription(scope, source),
    kind: "skill",
    name: lead,
  });
}
