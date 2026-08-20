import { MoreHorizontal, RefreshCw, Star } from "lucide-react";
import { type ReactNode, useState } from "react";
import type { Catalog, CatalogSummary, MarketplaceRow } from "@/bindings";
import { SubscribeFromRepo } from "@/components/marketplaces/subscribe-from-repo";
import { UnsubscribeDialog } from "@/components/marketplaces/unsubscribe-dialog";
import { PageHeader } from "@/components/page-header";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Switch } from "@/components/ui/switch";
import { cn } from "@/lib/utils";
import { useCommunityStore } from "@/stores/community";
import { useMarketplacesStore } from "@/stores/marketplaces";

/** The marketplace page's header for either kind of catalog: a
 * subscription's switch, refresh and unsubscribe, or a repository's one
 * Subscribe button. The words come from the catalog itself where it has
 * been read, and from the directory's listing until then. */
export function DetailHeader({
  requested,
  catalog,
  row,
  summary,
}: {
  /** What was opened — a repository keeps its listing's name and tags. */
  requested: Catalog;
  catalog: Catalog;
  row: MarketplaceRow | undefined;
  summary: CatalogSummary | null;
}) {
  const toggle = useMarketplacesStore((s) => s.toggle);
  const checkForUpdates = useMarketplacesStore((s) => s.checkForUpdates);
  const busy = useMarketplacesStore((s) => s.busy);
  const listing = useCommunityStore((s) =>
    requested.by === "repo"
      ? s.directory?.rows.find((r) => r.repo === requested.repo)
      : undefined,
  );
  const [unsubscribeOpen, setUnsubscribeOpen] = useState(false);

  const meta = row?.meta ?? summary?.meta ?? null;
  const title =
    catalog.by === "subscription"
      ? catalog.source
      : (listing?.name ?? meta?.name ?? catalog.repo.split("/").at(-1));
  const description = meta?.description ?? listing?.description ?? null;
  const commit = row?.commit ?? summary?.commit ?? null;
  const metaLine = [
    row?.repo ?? row?.path ?? summary?.provenance ?? listing?.repo,
    commit ? `@ ${commit.slice(0, 7)}` : null,
    meta?.license,
    meta?.author ? `by ${meta.author}` : null,
  ].filter(Boolean);
  const tags = [...new Set([...(meta?.tags ?? []), ...(listing?.tags ?? [])])];

  let action: ReactNode;
  if (catalog.by === "subscription") {
    const { scope, source } = catalog;
    action = (
      <>
        {row ? (
          <Switch
            checked={row.enabled}
            onCheckedChange={(enabled) => void toggle(scope, source, enabled)}
            aria-label={row.enabled ? "Turn off" : "Turn on"}
          />
        ) : null}
        <Button
          size="sm"
          variant="outline"
          disabled={busy}
          onClick={() => void checkForUpdates()}
        >
          <RefreshCw className={cn("size-4", busy && "animate-spin")} />
          Check for updates
        </Button>
        <DropdownMenu>
          <DropdownMenuTrigger
            render={
              <Button size="icon-xs" variant="quiet" aria-label="More actions">
                <MoreHorizontal className="size-4" />
              </Button>
            }
          />
          <DropdownMenuContent align="end">
            <DropdownMenuItem
              className="text-critical"
              onClick={() => setUnsubscribeOpen(true)}
            >
              Unsubscribe…
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <UnsubscribeDialog
          open={unsubscribeOpen}
          onOpenChange={setUnsubscribeOpen}
          scope={scope}
          source={source}
        />
      </>
    );
  } else {
    action = <SubscribeFromRepo repo={catalog.repo} label="Subscribe" />;
  }

  return (
    <PageHeader
      wide
      title={
        <span className="flex items-center gap-2.5">
          {title}
          {listing?.featured ? (
            <Badge variant="secondary" className="gap-1">
              <Star className="size-3" /> featured
            </Badge>
          ) : null}
        </span>
      }
      subtitle={
        <>
          {description ? <p>{description}</p> : null}
          {metaLine.length > 0 ? (
            <p className="mt-1 font-mono text-xs">{metaLine.join(" · ")}</p>
          ) : null}
          {tags.length > 0 ? (
            <span className="mt-2 flex flex-wrap gap-1.5">
              {tags.map((tag) => (
                <Badge key={tag} variant="secondary">
                  {tag}
                </Badge>
              ))}
            </span>
          ) : null}
        </>
      }
      action={action}
    />
  );
}
