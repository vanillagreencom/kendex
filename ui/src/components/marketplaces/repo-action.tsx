import { RefreshCw } from "lucide-react";
import type { CatalogSummary, MarketplaceRow, Scope } from "@/bindings";
import { SubscribeFromRepo } from "@/components/marketplaces/subscribe-from-repo";
import { Button } from "@/components/ui/button";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import { MARKETPLACES_CHECK_FAILED_TITLE } from "@/lib/copy-marketplaces";
import { scopeLabel } from "@/lib/derive";
import { scopeName, scopeNames } from "@/lib/labels";
import { cn } from "@/lib/utils";
import { useCommunityStore } from "@/stores/community";
import { repoAction, useMarketplacesStore } from "@/stores/marketplaces";

/** The canonical key for a bare repository, from core rather than from the
 * spelling the page was opened with: the summary's once the fetch lands,
 * the directory listing's until then. Every surface deciding what a bare
 * repository offers reads it here — spelled twice, one of the two settles
 * on a spelling of its own and offers a Subscribe the engine refuses. */
export function useRepoKey(
  repo: string,
  summary: CatalogSummary | null,
): string | null {
  const listedKey = useCommunityStore(
    (s) => s.directory?.rows.find((r) => r.repo === repo)?.repoKey ?? null,
  );
  return summary?.repoKey ?? listedKey;
}

/** What one place is called among every place the overview knows. The
 * holder can be any of them, so a basename two of them share would name
 * neither; [scopeNames] substitutes the full path exactly there. */
function placeAmong(rows: MarketplaceRow[], scope: Scope): string {
  const places = [
    ...new Map(rows.map((row) => [scopeLabel(row.scope), row.scope])).values(),
  ];
  const at = places.findIndex((one) => scopeLabel(one) === scopeLabel(scope));
  return scopeNames(places)[at] ?? scopeName(scope);
}

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
  const key = useRepoKey(repo, summary);
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
      // The place is in the label, not left to be guessed: the holder comes
      // from declaredHolder, which can pick a project subscription while
      // the page names only the repository — and named against every place
      // the overview knows, so a basename two projects share does not name
      // both on a button that turns one of them on.
      return (
        <Button
          size="sm"
          onClick={() => holder && void toggle(holder.scope, holder.name, true)}
        >
          {holder ? `Turn on in ${placeAmong(rows, holder.scope)}` : "Turn on"}
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
