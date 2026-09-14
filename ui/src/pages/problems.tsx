import { CheckCircle2 } from "lucide-react";
import { BlockedDeclarations } from "@/components/blocked-declarations";
import {
  type AttentionCard,
  problemsPageRows,
} from "@/components/home/attention-rows";
import { AttentionSection } from "@/components/home/attention-section";
import { useAttentionRows } from "@/components/home/use-attention-rows";
import { PageHeader } from "@/components/page-header";
import { PlaceCard } from "@/components/place-card";
import { ProblemCard } from "@/components/problem-card";
import { UnreadableFileCard } from "@/components/unreadable-file-card";
import { BLOCKED_HEADLINE } from "@/lib/copy-in-the-way";
import { PROBLEMS_EMPTY, PROBLEMS_SUBTITLE } from "@/lib/error-copy";
import { scopeName, scopePath } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useAuditOnMount, useAuditStore } from "@/stores/audit";

export function ProblemsPage() {
  // Every item on this page is something the audit or the scan found;
  // opening it asks for a fresh answer rather than showing the last one.
  useAuditOnMount();
  // Only what the person must act on. An item with a card of its own keeps
  // it; every other item draws as the row Home shows, with the same action.
  const rows = problemsPageRows(useAttentionRows());

  return (
    <div>
      <PageHeader title="Problems" subtitle={PROBLEMS_SUBTITLE} />
      <div className={PAGE_BODY}>
        <div className={cn("space-y-4", CONTENT_WIDTH)}>
          {rows.map((row) =>
            row.card ? (
              <ItemCard key={row.key} card={row.card} />
            ) : (
              <AttentionSection key={row.key} rows={[row]} />
            ),
          )}
          {rows.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-16 text-center">
              <CheckCircle2 className="size-8 text-muted-foreground" />
              <p className="font-medium">{PROBLEMS_EMPTY}</p>
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}

function ItemCard({ card }: { card: AttentionCard }) {
  const busy = useAuditStore((s) => s.busy);
  const adopt = useAuditStore((s) => s.adopt);
  const replaceUnmanaged = useAuditStore((s) => s.replaceUnmanaged);

  switch (card.kind) {
    case "problem":
      return <ProblemCard problem={card.problem} />;
    case "unreadable-file":
      return <UnreadableFileCard warning={card.warning} />;
    case "blocked-place": {
      // One card per place: both exits run that place's whole plan, so a
      // list mixing two places would put a button under rows it does not
      // act on.
      const { place } = card;
      return (
        <PlaceCard
          tone="warning"
          headline={BLOCKED_HEADLINE}
          name={scopeName(place.scope)}
          path={scopePath(place.scope)}
        >
          <BlockedDeclarations
            rows={place.rows}
            exits={place.exits}
            alsoApplies={place.alsoApplies}
            busy={busy}
            onKeep={(kind, name, harnesses) =>
              adopt(place.scope, kind, name, harnesses)
            }
            onReplace={(kind, name) =>
              replaceUnmanaged(place.scope, kind, name)
            }
          />
        </PlaceCard>
      );
    }
    default:
      return card satisfies never;
  }
}
