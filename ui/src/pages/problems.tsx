import { CheckCircle2 } from "lucide-react";
import { BlockedDeclarations } from "@/components/blocked-declarations";
import { PageHeader } from "@/components/page-header";
import { PlaceCard } from "@/components/place-card";
import { ProblemCard } from "@/components/problem-card";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  AUDIT_ATTENTION_DETAIL,
  AUDIT_ATTENTION_TITLE,
  TRY_AGAIN_LABEL,
} from "@/lib/copy";
import { BLOCKED_HEADLINE } from "@/lib/copy-in-the-way";
import { PROBLEMS_EMPTY, PROBLEMS_SUBTITLE } from "@/lib/error-copy";
import { scopeName, scopePath } from "@/lib/labels";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useAuditOnMount, useAuditStore } from "@/stores/audit";
import { useBlockedPlaces, useProblems } from "@/stores/problems";

export function ProblemsPage() {
  // Every problem on this page is something the audit or the scan found;
  // opening it asks for a fresh answer rather than showing the last one.
  useAuditOnMount();
  const problems = useProblems();
  // Null where the last check failed. Every button behind these rows moves
  // the reader's own files, so an unconfirmed reading is not one to draw
  // them from — and the page says so rather than reporting itself clean.
  const blocked = useBlockedPlaces();
  const busy = useAuditStore((s) => s.busy);
  const refresh = useAuditStore((s) => s.refresh);
  const adopt = useAuditStore((s) => s.adopt);
  const replaceUnmanaged = useAuditStore((s) => s.replaceUnmanaged);

  return (
    <div>
      <PageHeader title="Problems" subtitle={PROBLEMS_SUBTITLE} />
      <div className={PAGE_BODY}>
        <div className={cn("space-y-4", CONTENT_WIDTH)}>
          {problems.map((problem) => (
            <ProblemCard key={problem.key} problem={problem} />
          ))}
          {blocked === null ? (
            <StatusNote
              tone="warning"
              title={AUDIT_ATTENTION_TITLE}
              action={
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() => void refresh({ force: true })}
                >
                  {TRY_AGAIN_LABEL}
                </Button>
              }
            >
              {AUDIT_ATTENTION_DETAIL}
            </StatusNote>
          ) : (
            // One card per place: both exits run that place's whole plan,
            // so a list mixing two places would put a button under rows it
            // does not act on.
            blocked.map((place) => (
              <PlaceCard
                key={place.key}
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
            ))
          )}
          {problems.length === 0 && blocked?.length === 0 ? (
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
