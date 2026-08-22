import { CheckCircle2 } from "lucide-react";
import { PageHeader } from "@/components/page-header";
import { ProblemCard } from "@/components/problem-card";
import { PROBLEMS_EMPTY, PROBLEMS_SUBTITLE } from "@/lib/error-copy";
import { CONTENT_WIDTH, PAGE_BODY } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { useProblems } from "@/stores/problems";

export function ProblemsPage() {
  const problems = useProblems();

  // Every place this page speaks about, so two projects sharing a folder
  // name are told apart on the cards that name them.
  const scopes = problems.flatMap((problem) =>
    problem.scope ? [problem.scope] : [],
  );
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
              <ProblemCard key={problem.key} problem={problem} among={scopes} />
            ))
          )}
        </div>
      </div>
    </div>
  );
}
