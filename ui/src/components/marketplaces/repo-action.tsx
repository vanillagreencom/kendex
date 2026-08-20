import { RefreshCw } from "lucide-react";
import type { CatalogSummary } from "@/bindings";
import { SubscribeFromRepo } from "@/components/marketplaces/subscribe-from-repo";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { repoAction, useMarketplacesStore } from "@/stores/marketplaces";

/** What a page browsing a bare repository offers. Subscribe only when no
 * subscription declares the repository; a declared one that is turned off
 * is turned back on from here, and one that is declared but unreadable is
 * refreshed — either way the page then carries on as it. */
export function RepoAction({
  repo,
  summary,
  subscribeLabel,
}: {
  /** The requested spelling, used until the summary names the canonical key. */
  repo: string;
  summary: CatalogSummary | null;
  subscribeLabel: string;
}) {
  const rows = useMarketplacesStore((s) => s.rows);
  const rowsCurrent = useMarketplacesStore((s) => s.rowsCurrent);
  const toggle = useMarketplacesStore((s) => s.toggle);
  const checkForUpdates = useMarketplacesStore((s) => s.checkForUpdates);
  const busy = useMarketplacesStore((s) => s.busy);
  const key = summary?.provenance ?? repo;
  const { kind, holder } = repoAction(rows, rowsCurrent, key);

  switch (kind) {
    case "checking":
      return (
        <Button size="sm" variant="outline" disabled>
          Checking subscriptions…
        </Button>
      );
    case "subscribe":
      return <SubscribeFromRepo repo={key} label={subscribeLabel} />;
    case "turn-on":
      return (
        <Button
          size="sm"
          onClick={() => holder && void toggle(holder.scope, holder.name, true)}
        >
          Turn on
        </Button>
      );
    case "refresh":
      return (
        <Button
          size="sm"
          variant="outline"
          disabled={busy}
          onClick={() => void checkForUpdates()}
        >
          <RefreshCw className={cn("size-4", busy && "animate-spin")} />
          Refresh
        </Button>
      );
  }
}
