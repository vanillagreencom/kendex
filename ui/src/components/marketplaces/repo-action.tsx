import { RefreshCw } from "lucide-react";
import type { CatalogSummary } from "@/bindings";
import { SubscribeFromRepo } from "@/components/marketplaces/subscribe-from-repo";
import { Button } from "@/components/ui/button";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import { MARKETPLACES_CHECK_FAILED_TITLE } from "@/lib/copy-marketplaces";
import { cn } from "@/lib/utils";
import { useCommunityStore } from "@/stores/community";
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
  /** The requested spelling — a directory row's or a skills.sh hit's. */
  repo: string;
  summary: CatalogSummary | null;
  subscribeLabel: string;
}) {
  const rows = useMarketplacesStore((s) => s.rows);
  const read = useMarketplacesStore((s) => s.read);
  const toggle = useMarketplacesStore((s) => s.toggle);
  const checkForUpdates = useMarketplacesStore((s) => s.checkForUpdates);
  const busy = useMarketplacesStore((s) => s.busy);
  const load = useMarketplacesStore((s) => s.load);
  // The canonical key comes from core — the directory row's from the first
  // render, or the summary's once it lands — never from the spelling.
  const listedKey = useCommunityStore(
    (s) => s.directory?.rows.find((r) => r.repo === repo)?.repoKey ?? null,
  );
  const key = summary?.repoKey ?? listedKey;
  const { kind, holder } = repoAction(rows, read, key);

  switch (kind) {
    // Nothing to match the repository against yet, for either of two
    // reasons: no canonical key, or no rows any read produced. Only the
    // second is the overview's to fix, and `load` is the only thing that
    // writes `read` — so Try again is offered where pressing it can lift
    // the state, and a key still on its way keeps the wait it is really
    // in. A retry that changed nothing visible would be the same dead
    // control under a friendlier word.
    case "checking":
      return read.status === "failed" && key !== null ? (
        <Button
          size="sm"
          variant="outline"
          title={`${MARKETPLACES_CHECK_FAILED_TITLE}: ${read.error}`}
          onClick={() => void load()}
        >
          {TRY_AGAIN_LABEL}
        </Button>
      ) : (
        <Button size="sm" variant="outline" disabled>
          Checking subscriptions…
        </Button>
      );
    case "subscribe":
      return <SubscribeFromRepo repo={key ?? repo} label={subscribeLabel} />;
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
