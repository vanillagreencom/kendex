import { ChevronRight } from "lucide-react";
import type { MarketplaceRow } from "@/bindings";
import {
  marketplaceIdentity,
  personalFirst,
  placeKey,
} from "@/components/marketplaces/subscribed-grouping";
import { Badge } from "@/components/ui/badge";
import { MARKETPLACE_PLACES_TITLE } from "@/lib/copy-marketplaces";
import { MARKETPLACE_PLACES_HELP, SWITCHED_OFF_HERE } from "@/lib/copy-model";
import { selectionOf } from "@/lib/derive";
import { scopeNames, scopePath } from "@/lib/labels";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";

/** Every place that installs from this marketplace, as a list of places to
 * open. It carries no control over a place: whether a place offers this
 * marketplace's packages is that place's own setting, reached from its card
 * on Projects, where the reader manages what that place has.
 *
 * One section of the About tab's source details, beside the alias and the
 * resolved location, so a person deciding whether to unsubscribe can see
 * who uses the source first. It heads itself, being one section of a panel
 * rather than a panel of its own. */
export function MarketplacePlaces({ identity }: { identity: string }) {
  const rows = useMarketplacesStore((s) => s.rows);
  const places = rows
    .filter((row) => marketplaceIdentity(row) === identity)
    .sort(personalFirst);

  if (places.length === 0) return null;
  // Named against each other, not one at a time: two registered projects
  // can end in the same folder, and a row labelled "kendex" beside another
  // labelled "kendex" names neither, over a link that opens one of them.
  // Where a basename is shared, [scopeNames] substitutes the full path.
  const named = scopeNames(places.map((row) => row.scope));

  return (
    <section>
      <h3 className="mb-2 text-[15px] font-semibold">
        {MARKETPLACE_PLACES_TITLE}
      </h3>
      <p className="max-w-prose text-sm text-muted-foreground">
        {MARKETPLACE_PLACES_HELP}
      </p>
      <div className="mt-4 divide-y rounded-lg border">
        {places.map((row, index) => (
          <PlaceRow key={placeKey(row)} row={row} place={named[index]} />
        ))}
      </div>
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
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const path = scopePath(row.scope);

  return (
    <button
      type="button"
      className="flex w-full cursor-pointer items-center gap-4 px-4 py-3 text-left hover:bg-accent/40"
      onClick={() => goToLibrary({ scope: selectionOf(row.scope) })}
    >
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
      {/* The state stays where a reader meets it, even though the switch
          that changes it does not: a place offering none of this
          marketplace's packages otherwise reads as a place with nothing
          installed. The way to change it is inside the place this row
          opens. */}
      {row.enabled ? null : (
        <Badge variant="outline" className="shrink-0">
          {SWITCHED_OFF_HERE}
        </Badge>
      )}
      <ChevronRight className="size-4 shrink-0 text-muted-foreground" />
    </button>
  );
}
