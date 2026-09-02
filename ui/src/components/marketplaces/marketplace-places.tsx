import { MoreHorizontal } from "lucide-react";
import { useState } from "react";
import type { MarketplaceRow } from "@/bindings";
import {
  marketplaceIdentity,
  personalFirst,
  placeKey,
} from "@/components/marketplaces/subscribed-grouping";
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
  SOURCE_ENABLED_HELP,
  SOURCE_ENABLED_LABEL,
} from "@/lib/copy-marketplaces";
import { scopeLabel } from "@/lib/derive";
import { scopeName, scopeNames, scopePath } from "@/lib/labels";
import { useMarketplacesStore } from "@/stores/marketplaces";

/** Every place that subscribes to this marketplace, and the one switch
 * each place has over it. The switch used to sit on the Subscribed list,
 * where it changed a place the list never named and said nothing about
 * what switching it off costs; here the place is the row and the sentence
 * under the list is the answer.
 *
 * Mounted as a tab panel, so it carries no heading of its own: the tab
 * spells [MARKETPLACE_PLACES_TITLE] already, and repeating it as an h2
 * would name the section twice on one screen. The sibling About panel
 * opens the same way. */
export function MarketplacePlaces({ identity }: { identity: string }) {
  const rows = useMarketplacesStore((s) => s.rows);
  const places = rows
    .filter((row) => marketplaceIdentity(row) === identity)
    .sort(personalFirst);

  if (places.length === 0) return null;
  // Named against each other, not one at a time: two registered projects
  // can end in the same folder, and a row labelled "kendex" beside another
  // labelled "kendex" names neither — over a switch that deactivates every
  // install this marketplace put in one of them. Where a basename is
  // shared, [scopeNames] substitutes the full path.
  const named = scopeNames(places.map((row) => row.scope));

  return (
    <section>
      <p className="max-w-prose text-sm text-muted-foreground">
        {MARKETPLACE_PLACES_HELP}
      </p>
      <div className="mt-4 divide-y rounded-lg border">
        {places.map((row, index) => (
          <PlaceRow key={placeKey(row)} row={row} place={named[index]} />
        ))}
      </div>
      <p className="mt-2 max-w-prose text-xs text-muted-foreground">
        {SOURCE_ENABLED_HELP}
      </p>
    </section>
  );
}

function PlaceRow({
  row,
  place,
}: {
  row: MarketplaceRow;
  /** What this place is called among the places drawn beside it. */
  place: string;
}) {
  const toggle = useMarketplacesStore((s) => s.toggle);
  const [unsubscribeOpen, setUnsubscribeOpen] = useState(false);
  const path = scopePath(row.scope);
  const switchId = `offer-${scopeLabel(row.scope)}-${row.name}`;

  return (
    <div className="flex items-center gap-4 px-4 py-3">
      <div className="min-w-0 flex-1">
        <p data-testid="place-name" className="truncate text-sm font-medium">
          {place}
        </p>
        {path ? (
          <p className="truncate font-mono text-xs text-muted-foreground">
            {path}
          </p>
        ) : null}
      </div>
      {/* The label is the switch's name, not a caption beside it: what the
          switch does has to be readable without pressing it, and a lone
          switch in a row of places names nothing.

          The place is in the label too, for a reader moving control to
          control who never meets the sibling text — every switch here would
          otherwise announce the same three words over a control that
          deactivates every install this marketplace put in one place. It is
          the full path rather than the basename, because two projects can
          end in the same folder name and would announce identically; the
          visible column keeps the short name, which is KEN-1142's to
          settle. */}
      <label
        htmlFor={switchId}
        className="shrink-0 cursor-pointer text-xs text-muted-foreground"
      >
        {SOURCE_ENABLED_LABEL}
        <span className="sr-only"> in {path ?? scopeName(row.scope)}</span>
      </label>
      <Switch
        id={switchId}
        checked={row.enabled}
        onCheckedChange={(enabled) => void toggle(row.scope, row.name, enabled)}
      />
      <PlaceActions
        place={place}
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
  place,
  source,
  onUnsubscribe,
}: {
  place: string;
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
            aria-label={`More actions for ${place}`}
          >
            <MoreHorizontal className="size-4" />
          </Button>
        }
      />
      <DropdownMenuContent align="end">
        <DropdownMenuItem className="text-critical" onClick={onUnsubscribe}>
          Unsubscribe {source} from {place}…
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
