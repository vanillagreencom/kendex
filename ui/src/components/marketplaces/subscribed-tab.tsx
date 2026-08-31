import { Store, TriangleAlert } from "lucide-react";
import type { MarketplaceRow, Scope } from "@/bindings";
import { EmptyState } from "@/components/empty-state";
import { SubscribedRow } from "@/components/marketplaces/subscribed-row";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  MARKETPLACES_CHECK_FAILED_TITLE,
  MARKETPLACES_EMPTY_TITLE,
  MARKETPLACES_UNCONFIRMED_TITLE,
} from "@/lib/copy-marketplaces";
import { scopeLabel } from "@/lib/derive";
import { scopeName, scopePath } from "@/lib/labels";
import { PAGE_BODY, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useMarketplacesStore } from "@/stores/marketplaces";

/** Every subscription, grouped by where it lives: personal first, then each
 * project under its own name — the same row shape throughout. */
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

  const groups = groupByScope(rows);
  return (
    <div className={cn(PAGE_BODY, "pt-0")}>
      <div className={cn(WIDE_CONTENT_WIDTH, "space-y-8")}>
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
        {groups.map(({ scope, list }) => (
          <section key={scopeLabel(scope)}>
            <div className="mb-2 flex items-baseline gap-2">
              <h2 className="text-sm font-semibold">{scopeName(scope)}</h2>
              {scopePath(scope) ? (
                <span className="truncate font-mono text-xs text-muted-foreground">
                  {scopePath(scope)}
                </span>
              ) : null}
            </div>
            <div className="divide-y rounded-lg border">
              {list.map((row) => (
                <SubscribedRow
                  key={`${scopeLabel(row.scope)}:${row.name}`}
                  row={row}
                />
              ))}
            </div>
          </section>
        ))}
      </div>
    </div>
  );
}

function groupByScope(rows: MarketplaceRow[]) {
  const groups: { scope: Scope; list: MarketplaceRow[] }[] = [];
  for (const row of rows) {
    const found = groups.find(
      (g) => scopeLabel(g.scope) === scopeLabel(row.scope),
    );
    if (found) found.list.push(row);
    else groups.push({ scope: row.scope, list: [row] });
  }
  // Personal leads; projects follow in the order settings lists them.
  groups.sort((a, b) =>
    a.scope.scope === "global" ? -1 : b.scope.scope === "global" ? 1 : 0,
  );
  return groups;
}
