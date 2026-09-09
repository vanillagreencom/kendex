import { useEffect, useMemo } from "react";
import type { Catalog, CatalogSummary } from "@/bindings";
import {
  displayFor,
  listedNameOf,
  type MarketplaceDisplay,
  rowForCatalog,
} from "@/lib/marketplace-display";
import { useCommunityStore } from "@/stores/community";
import {
  catalogKey,
  readErrorKey,
  subscription,
  useMarketplacesStore,
} from "@/stores/marketplaces";

/** The catalog a nested page really reads. A repository opened from the
 * Community tab is read once for what it says about itself — the read that
 * fetches it — and when this machine already subscribes to it, or does so
 * while the page is open, the page carries on as that subscription, Install
 * and all. Content reads wait for `ready`: a repository's first fetch holds
 * the store's lock, and a second read racing it would be refused. */
export function useCatalog(requested: Catalog): {
  catalog: Catalog;
  summary: CatalogSummary | null;
  /** What to call this marketplace, and where it comes from. Resolved here
   * because this is the one place holding both halves of the conversion:
   * the summary is cached under the REQUESTED repository's key, while
   * `catalog` is the subscription that summary discovered, so a surface
   * looking the summary up by the catalog it was handed finds nothing and
   * falls back to the alias while the breadcrumb beside it reads the
   * declared name. Every page naming a marketplace reads this rather than
   * resolving its own. */
  display: MarketplaceDisplay;
  error: string | null;
  ready: boolean;
  retry: () => void;
} {
  const key = catalogKey(requested);
  const summary = useMarketplacesStore((s) => s.summaries[key] ?? null);
  const rows = useMarketplacesStore((s) => s.rows);
  const directory = useCommunityStore((s) => s.directory?.rows);
  const error = useMarketplacesStore(
    (s) => s.readErrors[readErrorKey(key, "summary")] ?? null,
  );
  const loadSummary = useMarketplacesStore((s) => s.loadSummary);

  useEffect(() => {
    if (requested.by === "repo" && !summary && !error) {
      void loadSummary(requested);
    }
  }, [requested, summary, error, loadSummary]);

  const catalog = useMemo(
    () =>
      requested.by === "repo" && summary?.subscription
        ? subscription(summary.subscription.scope, summary.subscription.source)
        : requested,
    [requested, summary],
  );

  // The declaring row where one has landed, the summary that fetched the
  // catalog otherwise — and the directory's label under both, keyed on
  // what was opened, since a converted subscription is no directory row.
  const display = useMemo(
    () =>
      displayFor({
        catalog,
        row: rowForCatalog(rows, catalog),
        summary,
        listedName: listedNameOf(directory, requested),
      }),
    [catalog, rows, summary, directory, requested],
  );

  return {
    catalog,
    summary,
    display,
    error,
    ready: requested.by === "subscription" || summary !== null,
    retry: () => void loadSummary(requested),
  };
}

/** Whether a cached read is due: the slot is empty, nothing has refused
 * it, and the catalog is ready. A mutation empties the slot without
 * touching the catalog, so presence is what an effect must watch — the
 * failure guard keeps a refused read from being asked again and again. */
export const readDue = (
  present: boolean,
  failed: boolean,
  ready: boolean,
): boolean => ready && !present && !failed;

/** Issue `read` whenever [readDue] says so. */
export function useCachedRead(
  present: boolean,
  failed: boolean,
  ready: boolean,
  read: () => Promise<void>,
) {
  useEffect(() => {
    if (readDue(present, failed, ready)) void read();
  }, [present, failed, ready, read]);
}
