import { MoreHorizontal, RefreshCw } from "lucide-react";
import { useState } from "react";
import type { MarketplaceRow } from "@/bindings";
import { UnsubscribeDialog } from "@/components/marketplaces/unsubscribe-dialog";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Switch } from "@/components/ui/switch";
import { subscription, useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";

/** How many packages a subscription offers, in one phrase. */
function countsLabel(row: MarketplaceRow): string | null {
  if (!row.counts) return null;
  const total = Object.values(row.counts).reduce((sum, n) => sum + n, 0);
  return `${total} package${total === 1 ? "" : "s"}`;
}

export function SubscribedRow({ row }: { row: MarketplaceRow }) {
  const goToMarketplace = useNavStore((s) => s.goToMarketplace);
  const toggle = useMarketplacesStore((s) => s.toggle);
  const checkForUpdates = useMarketplacesStore((s) => s.checkForUpdates);
  const busy = useMarketplacesStore((s) => s.busy);
  const [unsubscribeOpen, setUnsubscribeOpen] = useState(false);

  const where = row.repo ?? row.path ?? "";
  const counts = countsLabel(row);

  return (
    <div className="flex items-center gap-4 px-4 py-3">
      <div className="min-w-0 flex-1">
        <div className="flex items-baseline gap-2">
          <span className="truncate font-medium">{row.name}</span>
          {row.rev ? (
            <span className="font-mono text-xs text-muted-foreground">
              @ {row.rev.slice(0, 7)}
            </span>
          ) : row.commit ? (
            <span className="font-mono text-xs text-muted-foreground">
              @ {row.commit.slice(0, 7)}
            </span>
          ) : null}
        </div>
        <div className="mt-0.5 flex items-center gap-2 text-xs text-muted-foreground">
          <span className="truncate font-mono">{where}</span>
          {counts ? <span className="shrink-0">· {counts}</span> : null}
          {!row.counts ? (
            <span className="shrink-0">· not fetched yet</span>
          ) : null}
        </div>
      </div>
      <Switch
        checked={row.enabled}
        onCheckedChange={(enabled) => void toggle(row.scope, row.name, enabled)}
        aria-label={row.enabled ? "Turn off" : "Turn on"}
      />
      <Button
        size="sm"
        variant="outline"
        onClick={() => goToMarketplace(subscription(row.scope, row.name))}
      >
        Open
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
            disabled={busy}
            onClick={() => void checkForUpdates()}
          >
            <RefreshCw className="size-4" /> Check for updates
          </DropdownMenuItem>
          <DropdownMenuItem
            onClick={() => void toggle(row.scope, row.name, !row.enabled)}
          >
            {row.enabled ? "Turn off" : "Turn on"}
          </DropdownMenuItem>
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
        scope={row.scope}
        source={row.name}
      />
    </div>
  );
}
