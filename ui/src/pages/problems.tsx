import { CheckCircle2 } from "lucide-react";
import { PageHeader } from "@/components/page-header";
import { ProblemCard } from "@/components/problem-card";
import { PROBLEMS_EMPTY, PROBLEMS_SUBTITLE } from "@/lib/error-copy";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useAuditOnMount } from "@/stores/audit";
import { useProblems } from "@/stores/problems";

export function ProblemsPage() {
  // Every problem on this page is something the audit or the scan found;
  // opening it asks for a fresh answer rather than showing the last one.
  useAuditOnMount();
  const problems = useProblems();

  return (
    <div>
      <PageHeader title="Problems" subtitle={PROBLEMS_SUBTITLE} />
      <div className={PAGE_BODY}>
        <div className={cn("space-y-4", CONTENT_WIDTH)}>
          {problems.length === 0 ? (
            <div className="flex flex-col items-center gap-2 py-16 text-center">
              <CheckCircle2 className="size-8 text-muted-foreground" />
              <p className="font-medium">{PROBLEMS_EMPTY}</p>
            </div>
          ) : (
            problems.map((problem) => (
              <ProblemCard key={problem.key} problem={problem} />
            ))
          )}
        </div>
      </div>
    </div>
  );
}
