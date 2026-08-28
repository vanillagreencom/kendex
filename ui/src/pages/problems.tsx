import { CheckCircle2 } from "lucide-react";
import { BlockedDeclarations } from "@/components/blocked-declarations";
import { PageHeader } from "@/components/page-header";
import { ProblemCard } from "@/components/problem-card";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
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
  const blocked = useBlockedPlaces();
  const busy = useAuditStore((s) => s.busy);
  const adopt = useAuditStore((s) => s.adopt);
  const replaceUnmanaged = useAuditStore((s) => s.replaceUnmanaged);

  return (
    <div>
      <PageHeader title="Problems" subtitle={PROBLEMS_SUBTITLE} />
      <div className={PAGE_BODY}>
        <div className={cn("space-y-4", CONTENT_WIDTH)}>
          {problems.length === 0 && blocked.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-16 text-center">
              <CheckCircle2 className="size-8 text-muted-foreground" />
              <p className="font-medium">{PROBLEMS_EMPTY}</p>
            </div>
          ) : (
            <>
              {problems.map((problem) => (
                <ProblemCard key={problem.key} problem={problem} />
              ))}
              {/* One card per place, named the way the cards above name
                  theirs. Both exits run that place's whole plan, so a list
                  mixing two places would put a button under rows it does
                  not act on. */}
              {blocked.map((place) => (
                <Card
                  key={place.key}
                  className="border-warning/30 bg-warning/5"
                >
                  <CardHeader>
                    <CardTitle className="text-base">
                      {BLOCKED_HEADLINE}
                    </CardTitle>
                  </CardHeader>
                  <CardContent className="space-y-3">
                    <div>
                      <p className="break-all text-sm font-medium">
                        {scopeName(place.scope)}
                      </p>
                      {scopePath(place.scope) ? (
                        <p className="truncate font-mono text-xs text-muted-foreground">
                          {scopePath(place.scope)}
                        </p>
                      ) : null}
                    </div>
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
                  </CardContent>
                </Card>
              ))}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
