import { useCallback, useEffect, useMemo, useState } from "react";
import type { AvailablePackage, Catalog } from "@/bindings";
import { AboutSection } from "@/components/marketplaces/about-section";
import { BundleCards } from "@/components/marketplaces/bundle-cards";
import { DetailHeader } from "@/components/marketplaces/detail-header";
import { useFollowUnsubscribed } from "@/components/marketplaces/follow-unsubscribed";
import { MarketplacePlaces } from "@/components/marketplaces/marketplace-places";
import { PackagesTable } from "@/components/marketplaces/packages-table";
import { marketplaceIdentity } from "@/components/marketplaces/subscribed-grouping";
import {
  useCachedRead,
  useCatalog,
} from "@/components/marketplaces/use-catalog";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { MARKETPLACE_PLACES_TITLE } from "@/lib/copy-marketplaces";
import { PAGE_BODY, PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";
import {
  catalogBundlesErrorKey,
  catalogKey,
  marketKey,
  readErrorKey,
  useMarketplacesStore,
} from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";

/** One marketplace's own page: what it offers and what it says about
 * itself — a subscription, or a repository opened from the Community tab
 * before subscribing, on the same surface. Nested under Marketplaces — the
 * breadcrumb strip above carries the way back. */
export function MarketplaceDetailPage() {
  const marketplaceRef = useNavStore((s) => s.marketplaceRef);
  if (!marketplaceRef) return null;
  return <MarketplaceDetail requested={marketplaceRef} />;
}

/** The stand-in for packages not read yet, stable across renders. */
const NONE: AvailablePackage[] = [];

function MarketplaceDetail({ requested }: { requested: Catalog }) {
  const { catalog, summary, error, ready, retry } = useCatalog(requested);
  const rows = useMarketplacesStore((s) => s.rows);
  const packages = useMarketplacesStore((s) => s.packages);
  const load = useMarketplacesStore((s) => s.load);
  const loadPackages = useMarketplacesStore((s) => s.loadPackages);
  const loadCatalogBundles = useMarketplacesStore((s) => s.loadCatalogBundles);

  const row =
    catalog.by === "subscription"
      ? rows.find(
          (r) =>
            r.name === catalog.source &&
            marketKey(r.scope, r.name) === catalogKey(catalog),
        )
      : undefined;
  // What every place declaring this same marketplace is keyed by — the
  // Projects section lists them all, not just the one this page opened as.
  const identity = row ? marketplaceIdentity(row) : null;
  const cached = packages[catalogKey(catalog)];
  // A shared empty rather than a fresh one: `entries` memoizes on this.
  const offered = cached ?? NONE;
  const packagesError = useMarketplacesStore(
    (s) => s.readErrors[readErrorKey(catalogKey(catalog), "packages")],
  );
  const bundles = useMarketplacesStore(
    (s) => s.catalogBundles[catalogKey(catalog)],
  );
  const bundlesError = useMarketplacesStore(
    (s) => s.readErrors[catalogBundlesErrorKey(catalog)],
  );

  useEffect(() => {
    void load();
  }, [load]);
  const readPackages = useCallback(
    () => loadPackages(catalog),
    [loadPackages, catalog],
  );
  useCachedRead(cached !== undefined, !!packagesError, ready, readPackages);
  const readBundles = useCallback(
    () => loadCatalogBundles(catalog),
    [loadCatalogBundles, catalog],
  );
  useCachedRead(bundles !== undefined, !!bundlesError, ready, readBundles);

  useFollowUnsubscribed(catalog, row, identity);

  // The tab is controlled so a section that stops existing cannot leave the
  // page with nothing selected: Projects is gone the moment the opened
  // place is, and an uncontrolled Tabs would keep pointing at it.
  const [tab, setTab] = useState("bundles");
  const shownTab = tab === "places" && !identity ? "bundles" : tab;

  // Stable identities: the table memoizes its ordering and its places join
  // on these, and this page re-renders as its packages, bundles, about and
  // error slices settle — a fresh object each time defeats both memos and
  // re-sorts and re-joins for nothing.
  const entries = useMemo(
    () =>
      offered.map((pkg) => ({
        catalog,
        row: pkg,
        // The subscription row this page was opened from carries the
        // scope's current record standing; a bare repository has no scope
        // of its own to ask.
        recordsUnreadable: row?.recordsUnreadable ?? false,
      })),
    [offered, catalog, row?.recordsUnreadable],
  );
  // What the subscription resolved to, which is what the lock recorded and
  // so what the places join matches on. Never the declaration's own `repo`
  // or `path`: a path source has no repo at all, and a manifest path may be
  // relative where the record is canonical.
  const repo = row?.provenance ?? summary?.provenance ?? null;
  const pageSubscription = useMemo(() => ({ catalog, repo }), [catalog, repo]);

  return (
    <div className="flex h-full flex-col">
      <DetailHeader
        requested={requested}
        catalog={catalog}
        row={row}
        summary={summary}
      />
      {error ? (
        <div className={cn(PAGE_BODY, "pt-0")}>
          <div className={WIDE_CONTENT_WIDTH}>
            <p className="text-sm text-critical" role="alert">
              This marketplace can't be reached right now — {error}
            </p>
            <Button
              className="mt-3"
              size="sm"
              variant="outline"
              onClick={retry}
            >
              Try again
            </Button>
          </div>
        </div>
      ) : !ready ? (
        <p className="py-16 text-center text-sm text-muted-foreground">
          Reaching {requested.by === "repo" ? requested.repo : ""}…
        </p>
      ) : (
        <Tabs
          value={shownTab}
          onValueChange={(value) => setTab(value as string)}
          className="flex min-h-0 flex-1 flex-col gap-0"
        >
          <div className={cn("pb-6", PAGE_GUTTER)}>
            <div className={WIDE_CONTENT_WIDTH}>
              <TabsList>
                <TabsTrigger value="bundles">Bundles</TabsTrigger>
                <TabsTrigger value="packages">Packages</TabsTrigger>
                {identity ? (
                  <TabsTrigger value="places">
                    {MARKETPLACE_PLACES_TITLE}
                  </TabsTrigger>
                ) : null}
                <TabsTrigger value="about">About</TabsTrigger>
              </TabsList>
            </div>
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto">
            <div className={cn(PAGE_BODY, "pt-0")}>
              <div className={WIDE_CONTENT_WIDTH}>
                {summary?.warning ? (
                  <p className="mb-4 text-xs text-warning">
                    Shown from the last download — {summary.warning}
                  </p>
                ) : null}
                <TabsContent value="bundles">
                  <BundleCards
                    catalog={catalog}
                    bundles={bundles}
                    error={bundlesError}
                  />
                </TabsContent>
                <TabsContent value="packages">
                  {packagesError ? (
                    <p
                      className="py-16 text-center text-sm text-critical"
                      role="alert"
                    >
                      Its packages can't be read right now — {packagesError}
                    </p>
                  ) : offered.length === 0 ? (
                    <p className="py-16 text-center text-sm text-muted-foreground">
                      Nothing to list yet — this marketplace hasn't been
                      fetched, or offers no packages.
                    </p>
                  ) : (
                    <PackagesTable
                      entries={entries}
                      showMarketplace={false}
                      subscription={pageSubscription}
                    />
                  )}
                </TabsContent>
                {identity ? (
                  <TabsContent value="places">
                    <MarketplacePlaces identity={identity} />
                  </TabsContent>
                ) : null}
                <TabsContent value="about">
                  <AboutSection
                    catalog={catalog}
                    meta={row?.meta ?? summary?.meta ?? null}
                    counts={row?.counts ?? summary?.counts ?? null}
                  />
                </TabsContent>
              </div>
            </div>
          </div>
        </Tabs>
      )}
    </div>
  );
}
