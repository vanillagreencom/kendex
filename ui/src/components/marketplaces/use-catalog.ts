import { useEffect, useMemo, useState } from "react";
import type { Catalog, CatalogSummary } from "@/bindings";
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
  error: string | null;
  ready: boolean;
  retry: () => void;
} {
  const key = catalogKey(requested);
  const summary = useMarketplacesStore((s) => s.summaries[key] ?? null);
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

  return {
    catalog,
    summary,
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

/** Issue `read` for the current subject, and report whether it is still
 * out. A page rendering a cached answer must not act on it until the read
 * that would confirm it lands: the cache may predate what it now describes,
 * and every action offered over it is judged against the fresher record.
 * `read` has to be stable — a new identity re-issues the read. */
export function useRefresh(ready: boolean, read: () => Promise<void>): boolean {
  const [refreshing, setRefreshing] = useState(false);
  useEffect(() => {
    if (!ready) return;
    let live = true;
    setRefreshing(true);
    void read().finally(() => {
      if (live) setRefreshing(false);
    });
    return () => {
      live = false;
    };
  }, [ready, read]);
  return refreshing;
}
