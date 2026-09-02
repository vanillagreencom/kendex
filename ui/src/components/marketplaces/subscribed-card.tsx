import { ChevronRight } from "lucide-react";
import type { SubscribedMarketplace } from "@/components/marketplaces/subscribed-grouping";
import { placeNames } from "@/components/marketplaces/subscribed-grouping";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { morePlacesLabel } from "@/lib/copy";
import { placeCountLabel } from "@/lib/copy-marketplaces";
import { shortRevision } from "@/lib/labels";
import { subscription } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";

/** How many place names fit on the card's line before the rest are counted. */
const NAMED_PLACES = 3;

/** One subscribed marketplace: what it is, where it came from, and which
 * places hold it. The whole card opens the marketplace's own page — the
 * per-place switch lives there now, in its Projects section, so this card
 * carries no control that changes anything from a list. */
export function SubscribedCard({ group }: { group: SubscribedMarketplace }) {
  const goToMarketplace = useNavStore((s) => s.goToMarketplace);
  const names = placeNames(group);
  const shown = names.slice(0, NAMED_PLACES);
  const rest = names.length - shown.length;
  // What the subscription declares it reads — a pinned commit, or the tag
  // or branch it tracks — else the commit it currently reads, which nothing
  // declared. Named for what it is: `rev` is a ref as often as a commit id,
  // and `commit` is never pinned.
  const revision = group.open.rev ?? group.open.commit;
  const off = group.places.filter((row) => !row.enabled).length;

  return (
    <Card className="gap-0 overflow-hidden py-0 transition-colors hover:border-input">
      <button
        type="button"
        className="flex w-full cursor-pointer items-start gap-3 px-4 py-3.5 text-left hover:bg-accent/40"
        onClick={() =>
          goToMarketplace(subscription(group.open.scope, group.open.name))
        }
      >
        <div className="min-w-0 flex-1 space-y-1">
          <div className="flex items-baseline gap-2">
            <span className="truncate font-medium">{group.name}</span>
            {revision ? (
              <span className="shrink-0 font-mono text-xs text-muted-foreground">
                @ {shortRevision(revision)}
              </span>
            ) : null}
            {off > 0 ? (
              <Badge variant="outline" className="shrink-0">
                {off === group.places.length ? "Switched off" : `Off in ${off}`}
              </Badge>
            ) : null}
          </div>
          <p className="truncate font-mono text-xs text-muted-foreground">
            {group.where}
          </p>
          <p className="text-xs text-muted-foreground">
            {placeCountLabel(group.places.length)}
            {shown.length > 0 ? ` · ${shown.join(", ")}` : ""}
            {rest > 0 ? `, ${morePlacesLabel(rest)}` : ""}
          </p>
        </div>
        <span className="flex shrink-0 items-center gap-2 pt-0.5 text-xs whitespace-nowrap text-muted-foreground tabular-nums">
          {group.packages === null
            ? "Not fetched yet"
            : `${group.packages} package${group.packages === 1 ? "" : "s"}`}
          <ChevronRight className="size-4" />
        </span>
      </button>
    </Card>
  );
}
