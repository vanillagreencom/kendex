import { MoreHorizontal } from "lucide-react";
import { useState } from "react";
import type { MarketplaceRow, Scope } from "@/bindings";
import { UnsubscribeDialog } from "@/components/marketplaces/unsubscribe-dialog";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Switch } from "@/components/ui/switch";
import {
  MARKETPLACE_PLACES_HELP,
  MARKETPLACE_PLACES_TITLE,
  SOURCE_ENABLED_HELP,
  SOURCE_ENABLED_LABEL,
} from "@/lib/copy-marketplaces";
import { scopeLabel } from "@/lib/derive";
import { scopeName, scopePath } from "@/lib/labels";
import { useMarketplacesStore } from "@/stores/marketplaces";

/** Every place that subscribes to this marketplace, and the one switch
 * each place has over it. The switch used to sit on the Subscribed list,
 * where it changed a place the list never named and said nothing about
 * what switching it off costs; here the place is the row and the sentence
 * under the heading is the answer. */
export function MarketplacePlaces({ identity }: { identity: string }) {
  const rows = useMarketplacesStore((s) => s.rows);
  const places = rows
    .filter((row) => (row.repoKey ?? row.path ?? row.name) === identity)
    .sort((a, b) =>
      a.scope.scope === "global" ? -1 : b.scope.scope === "global" ? 1 : 0,
    );

  if (places.length === 0) return null;

  return (
    <section>
      <h2 className="text-sm font-semibold">{MARKETPLACE_PLACES_TITLE}</h2>
      <p className="mt-1 max-w-prose text-sm text-muted-foreground">
        {MARKETPLACE_PLACES_HELP}
      </p>
      <div className="mt-4 divide-y rounded-lg border">
        {places.map((row) => (
          <PlaceRow key={`${scopeLabel(row.scope)}:${row.name}`} row={row} />
        ))}
      </div>
      <p className="mt-2 max-w-prose text-xs text-muted-foreground">
        {SOURCE_ENABLED_HELP}
      </p>
    </section>
  );
}

function PlaceRow({ row }: { row: MarketplaceRow }) {
  const toggle = useMarketplacesStore((s) => s.toggle);
  const [unsubscribeOpen, setUnsubscribeOpen] = useState(false);
  const path = scopePath(row.scope);
  const switchId = `offer-${scopeLabel(row.scope)}-${row.name}`;

  return (
    <div className="flex items-center gap-4 px-4 py-3">
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium">{scopeName(row.scope)}</p>
        {path ? (
          <p className="truncate font-mono text-xs text-muted-foreground">
            {path}
          </p>
        ) : null}
      </div>
      {/* The label is the switch's name, not a caption beside it: what the
          switch does has to be readable without pressing it, and a lone
          switch in a row of places names nothing. */}
      <label
        htmlFor={switchId}
        className="shrink-0 cursor-pointer text-xs text-muted-foreground"
      >
        {SOURCE_ENABLED_LABEL}
      </label>
      <Switch
        id={switchId}
        checked={row.enabled}
        onCheckedChange={(enabled) => void toggle(row.scope, row.name, enabled)}
      />
      <PlaceActions
        scope={row.scope}
        source={row.name}
        onUnsubscribe={() => setUnsubscribeOpen(true)}
      />
      <UnsubscribeDialog
        open={unsubscribeOpen}
        onOpenChange={setUnsubscribeOpen}
        scope={row.scope}
        source={row.name}
      />
    </div>
  );
}

function PlaceActions({
  scope,
  source,
  onUnsubscribe,
}: {
  scope: Scope;
  source: string;
  onUnsubscribe: () => void;
}) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button
            size="icon-xs"
            variant="quiet"
            aria-label={`More actions for ${scopeName(scope)}`}
          >
            <MoreHorizontal className="size-4" />
          </Button>
        }
      />
      <DropdownMenuContent align="end">
        <DropdownMenuItem className="text-critical" onClick={onUnsubscribe}>
          Unsubscribe {source} from {scopeName(scope)}…
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
