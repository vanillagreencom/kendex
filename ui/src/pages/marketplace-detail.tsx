import { useCallback, useEffect, useRef, useState } from "react";
import type { Catalog } from "@/bindings";
import { AboutSection } from "@/components/marketplaces/about-section";
import { BundleCards } from "@/components/marketplaces/bundle-cards";
import { DetailHeader } from "@/components/marketplaces/detail-header";
import { MarketplacePlaces } from "@/components/marketplaces/marketplace-places";
import { PackagesTable } from "@/components/marketplaces/packages-table";
import {
  marketplaceIdentity,
  openPlace,
  personalFirst,
} from "@/components/marketplaces/subscribed-grouping";
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
  subscription,
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

function MarketplaceDetail({ requested }: { requested: Catalog }) {
  const { catalog, summary, error, ready, retry } = useCatalog(requested);
  const rows = useMarketplacesStore((s) => s.rows);
  const packages = useMarketplacesStore((s) => s.packages);
  const load = useMarketplacesStore((s) => s.load);
  const read = useMarketplacesStore((s) => s.read);
  const goToMarketplace = useNavStore((s) => s.goToMarketplace);
  const leaveMarketplace = useNavStore((s) => s.leaveMarketplace);
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
  const offered = cached ?? [];
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

  // Unsubscribing from the Projects section can remove the very place this
  // page opened as. The row goes, and with it the tab the person was
  // reading — so the page follows the marketplace to another place still
  // holding it, or leaves for the list when none does. The identity has to
  // outlive the row to do that, and only a read that landed may be taken
  // as proof the place is gone: rows are empty before the first read and
  // after a failed one, and neither is an unsubscribe.
  const lastIdentity = useRef<string | null>(null);
  useEffect(() => {
    if (identity) lastIdentity.current = identity;
  }, [identity]);
  useEffect(() => {
    if (catalog.by !== "subscription" || row || read.status !== "landed")
      return;
    const held = lastIdentity.current;
    if (!held) return;
    // The same pick the card makes, from the same helper: a place actually
    // offering packages, personal before a project. First-in-overview-order
    // would land the reader on a switched-off place.
    const elsewhere = openPlace(
      rows.filter((r) => marketplaceIdentity(r) === held).sort(personalFirst),
    );
    if (elsewhere) {
      goToMarketplace(subscription(elsewhere.scope, elsewhere.name));
    } else {
      // Left, not navigated away from: this page is a subscription that no
      // longer exists, so it must not be somewhere Back can return to.
      leaveMarketplace("subscribed");
    }
  }, [catalog, row, read.status, rows, goToMarketplace, leaveMarketplace]);

  // The tab is controlled so a section that stops existing cannot leave the
  // page with nothing selected: Projects is gone the moment the opened
  // place is, and an uncontrolled Tabs would keep pointing at it.
  const [tab, setTab] = useState("bundles");
  const shownTab = tab === "places" && !identity ? "bundles" : tab;

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
                      entries={offered.map((pkg) => ({
                        catalog,
                        row: pkg,
                        // The subscription row this page was opened from
                        // carries the scope's current record standing; a
                        // bare repository has no scope of its own to ask.
                        recordsUnreadable: row?.recordsUnreadable ?? false,
                      }))}
                      showMarketplace={false}
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
