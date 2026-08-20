import { useEffect, useMemo } from "react";
import type { Catalog, CatalogSummary } from "@/bindings";
import {
  catalogKey,
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
  error: string | null;
  ready: boolean;
  retry: () => void;
} {
  const key = catalogKey(requested);
  const summary = useMarketplacesStore((s) => s.summaries[key] ?? null);
  const error = useMarketplacesStore(
    (s) => s.readErrors[`${key}::summary`] ?? null,
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

  return {
    catalog,
    summary,
    error,
    ready: requested.by === "subscription" || summary !== null,
    retry: () => void loadSummary(requested),
  };
}
