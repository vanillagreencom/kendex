import { Store, TriangleAlert } from "lucide-react";
import { EmptyState } from "@/components/empty-state";
import { SubscribedCard } from "@/components/marketplaces/subscribed-card";
import { groupByMarketplace } from "@/components/marketplaces/subscribed-grouping";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  MARKETPLACES_CHECK_FAILED_TITLE,
  MARKETPLACES_EMPTY_TITLE,
  MARKETPLACES_UNCONFIRMED_TITLE,
} from "@/lib/copy-marketplaces";
import { PAGE_BODY, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useMarketplacesStore } from "@/stores/marketplaces";

/** One card per marketplace, whatever number of places subscribe to it —
 * a catalog held personally and by three projects is one catalog, not four
 * rows of the same names. The card opens the marketplace; which places hold
 * it, and whether each offers its packages, is answered there. */
export function SubscribedTab({ onSubscribe }: { onSubscribe: () => void }) {
  const rows = useMarketplacesStore((s) => s.rows);
  // The read's own outcome, not the store's shared `error`: actions write
  // the shared field too, and a failed subscribe is not a failed overview
  // read.
  const read = useMarketplacesStore((s) => s.read);
  const load = useMarketplacesStore((s) => s.load);

  if (read.status !== "pending" && rows.length === 0) {
    // Empty with nothing retained from a read that failed is a failure to
    // show, not an invitation to subscribe: "No marketplaces yet" here
    // would assert an emptiness nobody could check.
    if (read.status === "failed") {
      return (
        <EmptyState
          icon={TriangleAlert}
          title={MARKETPLACES_CHECK_FAILED_TITLE}
          action={
            <Button variant="outline" onClick={() => void load()}>
              {TRY_AGAIN_LABEL}
            </Button>
          }
        >
          {read.error}
        </EmptyState>
      );
    }
    return (
      <EmptyState
        icon={Store}
        title={MARKETPLACES_EMPTY_TITLE}
        action={<Button onClick={onSubscribe}>Subscribe to one</Button>}
      >
        Subscribe to a repository of skills and agents to start installing from
        it.
      </EmptyState>
    );
  }

  const groups = groupByMarketplace(rows);
  return (
    <div className={cn(PAGE_BODY, "pt-0")}>
      <div className={cn(WIDE_CONTENT_WIDTH, "space-y-4")}>
        {/* Rows kept from before a failed read stay on screen — right —
            but headed as what they are: the last read that answered, not
            confirmed subscriptions. Their actions stay live, and the
            engine refuses whatever they turn out to be wrong about. */}
        {read.status === "failed" ? (
          <StatusNote
            tone="warning"
            title={MARKETPLACES_UNCONFIRMED_TITLE}
            action={
              <Button size="sm" variant="outline" onClick={() => void load()}>
                {TRY_AGAIN_LABEL}
              </Button>
            }
          >
            {read.error}
          </StatusNote>
        ) : null}
        <div className="grid gap-3 md:grid-cols-2 2xl:grid-cols-3">
          {groups.map((group) => (
            <SubscribedCard key={group.key} group={group} />
          ))}
        </div>
      </div>
    </div>
  );
}
