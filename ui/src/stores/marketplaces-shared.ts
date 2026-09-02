// The cache vocabulary the marketplaces store and its readers share: the
// collision-free subscription key, and the invalidation every catalog-moving
// mutation runs.
import type {
  AboutView,
  AvailablePackage,
  BundleDetail,
  Catalog,
  CatalogSummary,
  MarketplaceRow,
  Scope,
} from "@/bindings";
import { invalidations, type ReadState } from "@/lib/read-state";
import { resetPreinstallSafety } from "./preinstall-safety";

/** Every cached catalog read the store holds, declared once here so the
 * store, the reads that fill it and the drops that empty it cannot disagree
 * about a field name — a rename lands on all three or on none. */
export interface CatalogCaches {
  /** Each opened catalog's offered packages, by [catalogKey]. */
  packages: Record<string, AvailablePackage[]>;
  /** Each opened catalog's About report, by [catalogKey]. */
  about: Record<string, AboutView>;
  /** Each opened catalog's own account of itself, by [catalogKey] — for a
   * repository this is the read that fetches it. */
  summaries: Record<string, CatalogSummary>;
  /** Each opened curated set, by [bundleKey]. */
  bundles: Record<string, BundleDetail>;
  /** Each opened catalog's declared curated sets, by [catalogKey] — what the
   * Bundles tab lists, straight from the catalog rather than derived from
   * the packages it offers. */
  catalogBundles: Record<string, BundleDetail[]>;
  /** Why a read produced nothing, by the same keys — the page the person is
   * looking at says it instead of loading forever. */
  readErrors: Record<string, string>;
}

/** Bumped once by [droppedSetCaches] and [dropCatalogCaches], the only two
 * places a drop is declared. A read that began before one describes a
 * checkout that may no longer be the one installed from, and every derived
 * cache keys on presence rather than freshness — a stale answer landing in
 * the emptied slot would pin the commit before the change for the session,
 * with nothing left to ask again. Shared with the pre-install scores, which
 * the same drop clears. */
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

/** Both caches carrying a curated set's member states, emptied — the opened
 * set and the list of sets a catalog declares, holding the same per-member
 * `InstallState` and the counts derived from it. An install moves those
 * states, so the two go together: one left behind is a card confidently
 * showing the count from before the install.
 *
 * Declaring the drop is half of this act, not a separate one a caller can
 * forget. Emptying a slot only makes the page ask again; a read already in
 * flight still lands, and `settle` refuses it solely on the generation this
 * bumps. Without that, the answer from before the install fills the slot
 * that was just emptied and presence-based `readDue` never asks again. So
 * the empty caches are only reachable through this call, and the
 * invalidation comes with them. */
export const droppedSetCaches = (): Pick<
  CatalogCaches,
  "bundles" | "catalogBundles"
> => {
  catalogDrops.moved();
  // Everything keyed to that generation goes with the bump. A pre-install
  // scan in flight is discarded on it, and only this reset clears the
  // `queued` mark the discard leaves behind — without it the row's score is
  // never asked for again and it reads "Checking…" for the session.
  resetPreinstallSafety();
  return { bundles: {}, catalogBundles: {} };
};

/** A mutation that can change what any catalog offers empties every derived
 * cache — the pages re-read, and pre-install scores are re-asked, so nothing
 * keeps describing the commit before the change. Summaries go with them: a
 * summary says which subscription a page carries on as, and a mutation is
 * exactly what changes that answer. */
export function dropCatalogCaches(set: (partial: CatalogCaches) => void) {
  set({
    packages: {},
    // Declares the invalidation for the whole drop, and clears what else
    // hangs off it, before anything is emptied: the object is built before
    // `set` is called.
    ...droppedSetCaches(),
    about: {},
    summaries: {},
    readErrors: {},
  });
}

/** The error key one cached read fails under, kept apart from the other
 * reads of the same catalog so a later success elsewhere never erases it. */
export const readErrorKey = (key: string, read: string): string =>
  `${key}::${read}`;

/** The key a failed catalog-level curated-set read lands under. One
 * function for the read that writes it and the page that subscribes to it,
 * the way [bundleKey] already serves the per-name set: spelled twice, the
 * two ends drift and the page loads forever with the reason under a key
 * nothing reads. */
export const catalogBundlesErrorKey = (catalog: Catalog): string =>
  readErrorKey(catalogKey(catalog), "bundles");

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
type RepoActionKind = "checking" | "subscribe" | "turn-on" | "refresh";

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
