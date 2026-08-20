// The cache vocabulary the marketplaces store and its readers share: the
// collision-free subscription key, and the invalidation every catalog-moving
// mutation runs.
import { type Catalog, commands, type Scope } from "@/bindings";
import { useAuditStore } from "./audit";
import type { MarketplacesState } from "./marketplaces";
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

/** One cached read landing: the answer under its key, or why there is
 * none — `suffix` keeps a summary's failure apart from the packages' under
 * the same catalog, since the page shows each where it belongs. */
export async function settle<
  S extends { readErrors: Record<string, string> },
  F extends keyof S,
>(
  set: (fn: (state: S) => Partial<S>) => void,
  field: F,
  key: string,
  pending: Promise<
    | { status: "ok"; data: S[F][keyof S[F]] }
    | { status: "error"; error: string }
  >,
  suffix?: string,
) {
  const errorKey = suffix ? readErrorKey(key, suffix) : key;
  const response = await pending;
  if (response.status === "ok") {
    set(
      (state) =>
        ({
          [field]: { ...state[field], [key]: response.data },
          readErrors: without(state.readErrors, errorKey),
        }) as Partial<S>,
    );
  } else {
    set(
      (state) =>
        ({
          readErrors: { ...state.readErrors, [errorKey]: response.error },
        }) as Partial<S>,
    );
  }
}

type Set = (
  fn: (state: MarketplacesState) => Partial<MarketplacesState>,
) => void;

/** The store's four cached reads, each landing under its own key and
 * failing under its own error key. */
export function catalogReads(set: Set) {
  return {
    loadPackages: (catalog: Catalog) =>
      settle(
        set,
        "packages",
        catalogKey(catalog),
        commands.marketplacePackages(catalog),
        "packages",
      ),
    loadSummary: (catalog: Catalog) =>
      settle(
        set,
        "summaries",
        catalogKey(catalog),
        commands.marketplaceSummary(catalog),
        "summary",
      ),
    loadAbout: (catalog: Catalog) =>
      settle(
        set,
        "about",
        catalogKey(catalog),
        commands.marketplaceAbout(catalog),
        "about",
      ),
    loadBundle: (catalog: Catalog, name: string) =>
      settle(
        set,
        "bundles",
        `${catalogKey(catalog)}::${name}`,
        commands.marketplaceBundle(catalog, name),
      ),
  };
}
