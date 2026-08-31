// The cache vocabulary the marketplaces store and its readers share: the
// collision-free subscription key, and the invalidation every catalog-moving
// mutation runs.
import type { Catalog, MarketplaceRow, Scope } from "@/bindings";
import { invalidations, type ReadState } from "@/lib/read-state";
import { resetPreinstallSafety } from "./preinstall-safety";

/** Bumped once by [dropCatalogCaches], the one place a drop is declared. A
 * read that began before one describes a checkout that may no longer be the
 * one installed from, and every derived cache keys on presence rather than
 * freshness — a stale answer landing in the emptied slot would pin the
 * commit before the change for the session, with nothing left to ask
 * again. Shared with the pre-install scores, which the same drop clears. */
export const catalogDrops = invalidations();

/** One subscription's cache key: where it lives plus its alias, encoded so
 * a root or alias containing the delimiter can never collide with another
 * subscription's key. */
export const marketKey = (scope: Scope, source: string): string =>
  JSON.stringify(["sub", scope.scope === "global" ? null : scope.root, source]);

/** Any catalog's cache key — a subscription's is [marketKey], so what a
 * subscription's rows cached stays found when a page addresses it. Each
 * shape carries its own tag, so a project root and alias can never spell
 * a repository's key. */
export const catalogKey = (catalog: Catalog): string =>
  catalog.by === "subscription"
    ? marketKey(catalog.scope, catalog.source)
    : JSON.stringify(["repo", catalog.repo]);

/** The repositories the live subscription list holds, by canonical key —
 * what a Community row's Subscribed marker reads, so it flips the moment
 * a subscription lands or goes, wherever that happened. */
export const subscribedKeys = (rows: MarketplaceRow[]): Set<string> =>
  new Set(rows.flatMap((row) => (row.repoKey ? [row.repoKey] : [])));

/** The subscription the live list already declares for a repository the
 * page is browsing bare — `summary` left it bare because that subscription
 * is turned off or unreadable, so Subscribe would be refused as a
 * duplicate. An enabled one outranks a disabled one. */
export const declaredHolder = (
  rows: MarketplaceRow[],
  repoKey: string,
): MarketplaceRow | null =>
  rows.find((row) => row.repoKey === repoKey && row.enabled) ??
  rows.find((row) => row.repoKey === repoKey) ??
  null;

/** A Community row's Subscribed marker. The directory's own flag is only
 * a stand-in until the live subscription list has loaded; after that the
 * list alone decides, so an unsubscribe clears the marker as surely as a
 * subscribe sets it. */
export const rowSubscribed = (
  row: { repoKey: string | null; subscribed: boolean },
  live: Set<string> | null,
): boolean =>
  live ? row.repoKey !== null && live.has(row.repoKey) : row.subscribed;

/** Whether a [catalogKey] names a repository rather than a subscription. */
export const isRepoKey = (key: string): boolean =>
  (JSON.parse(key) as unknown[])[0] === "repo";

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

export function without<T>(
  map: Record<string, T>,
  key: string,
): Record<string, T> {
  const { [key]: _, ...rest } = map;
  return rest;
}

/** A mutation that can change what any catalog offers empties every derived
 * cache — the pages re-read, and pre-install scores are re-asked, so nothing
 * keeps describing the commit before the change. Summaries go with them: a
 * summary says which subscription a page carries on as, and a mutation is
 * exactly what changes that answer. */
export function dropCatalogCaches(set: (partial: object) => void) {
  // Before anything is emptied, and once for the whole drop: this is where
  // the invalidation is declared, so it cannot be stubbed out from under
  // the caches it guards.
  catalogDrops.moved();
  resetPreinstallSafety();
  set({
    packages: {},
    bundles: {},
    about: {},
    summaries: {},
    readErrors: {},
  });
}

/** The error key one cached read fails under, kept apart from the other
 * reads of the same catalog so a later success elsewhere never erases it. */
export const readErrorKey = (key: string, read: string): string =>
  `${key}::${read}`;

/** A tree or skills.sh URL was pointing at one package; land on it so
 * Install is the next click, with its safety score in view. */
export async function openLead(scope: Scope, source: string, lead: string) {
  const { useNavStore } = await import("./nav");
  useNavStore.getState().goToAvailablePackage({
    catalog: subscription(scope, source),
    kind: "skill",
    name: lead,
  });
}

/** What a page browsing a bare repository offers, decided from the live
 * subscription list and the repository's canonical key.
 *
 * Two things have to be known first, or Subscribe is offered on a guess and
 * a declared repository refuses it. The key, which comes from the
 * directory's row or the summary and never from the requested spelling,
 * which may differ in case. And rows some read actually produced: with none,
 * every repository looks undeclared, and a read that has not landed is no
 * reason to believe that. Rows kept from a read that later failed are what
 * this machine last knew and go on being acted on — the engine refuses
 * whatever they were wrong about — so it is the emptiness that holds the
 * page neutral, not the failure. */
export type RepoActionKind = "checking" | "subscribe" | "turn-on" | "refresh";

export function repoAction(
  rows: MarketplaceRow[],
  read: ReadState,
  repoKey: string | null,
): { kind: RepoActionKind; holder: MarketplaceRow | null } {
  if (repoKey === null || (read.status !== "landed" && rows.length === 0)) {
    return { kind: "checking", holder: null };
  }
  const holder = declaredHolder(rows, repoKey);
  if (!holder) return { kind: "subscribe", holder: null };
  return { kind: holder.enabled ? "refresh" : "turn-on", holder };
}
