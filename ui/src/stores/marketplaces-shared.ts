// The cache vocabulary the marketplaces store and its readers share: the
// collision-free subscription key, and the invalidation every catalog-moving
// mutation runs.
import type {
  Catalog,
  CatalogSummary,
  MarketplaceRow,
  Scope,
} from "@/bindings";
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
  key.startsWith(JSON.stringify(["repo", ""]).slice(0, -3));

/** Every repository catalog with a cached summary — the pages to re-ask
 * after a refresh may have made a holder readable. The key is the way
 * back to the catalog, read in place so the old summary stands until the
 * new one lands. */
export const cachedRepoCatalogs = (
  summaries: Record<string, unknown>,
): Catalog[] =>
  Object.keys(summaries)
    .filter(isRepoKey)
    .map((key) => ({
      by: "repo",
      repo: (JSON.parse(key) as [string, string])[1],
    }));

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
  generation += 1;
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

/** Every summary about one subscription's repository — matched by the
 * canonical key, however the declaration spells the repository, or by the
 * subscription itself — so a toggled holder is re-asked in both
 * directions: turned off, the page falls back to the bare repository;
 * turned on, it carries on again. */
export function dropSummariesHeldBy(
  set: (
    fn: (state: { summaries: Record<string, CatalogSummary> }) => object,
  ) => void,
  rows: MarketplaceRow[],
  scope: Scope,
  source: string,
) {
  const held = marketKey(scope, source);
  const repoKey =
    rows.find((row) => marketKey(row.scope, row.name) === held)?.repoKey ??
    null;
  set((state) => ({
    summaries: Object.fromEntries(
      Object.entries(state.summaries).filter(([key, summary]) => {
        if (!isRepoKey(key)) return true;
        const sameRepo = repoKey !== null && summary.repoKey === repoKey;
        const carried =
          summary.subscription !== null &&
          marketKey(summary.subscription.scope, summary.subscription.source) ===
            held;
        return !sameRepo && !carried;
      }),
    ),
  }));
}

/** What a page browsing a bare repository offers, decided from the live
 * subscription list. Until an overview has succeeded the list is not to
 * be trusted, and Subscribe — which a declared repository would refuse —
 * is not offered on a guess. */
export type RepoActionKind = "checking" | "subscribe" | "turn-on" | "refresh";

export function repoAction(
  rows: MarketplaceRow[],
  rowsCurrent: boolean,
  repoKey: string,
): { kind: RepoActionKind; holder: MarketplaceRow | null } {
  if (!rowsCurrent) return { kind: "checking", holder: null };
  const holder = declaredHolder(rows, repoKey);
  if (!holder) return { kind: "subscribe", holder: null };
  return { kind: holder.enabled ? "refresh" : "turn-on", holder };
}

/** Bumped by every cache drop. A read that began under an older generation
 * describes a checkout that may no longer be the one installed from, and
 * its answer is discarded rather than stored. */
let generation = 0;
export const readGeneration = (): number => generation;
