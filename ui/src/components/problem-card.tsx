import { useState } from "react";
import { commands, type Scope } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { PROBLEM_HEADLINES, PROBLEM_STEPS } from "@/lib/error-copy";
import { scopeName, scopePath } from "@/lib/labels";
import { useAuditStore } from "@/stores/audit";
import type { Problem } from "@/stores/problems";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";

export function ProblemCard({
  problem,
  among = [],
}: {
  problem: Problem;
  /** Every place the list this card sits in speaks about, so two projects
   *  sharing a folder name are named apart. */
  among?: Scope[];
}) {
  const [confirmRemove, setConfirmRemove] = useState(false);
  const refreshScan = useScanStore((s) => s.refresh);
  const refreshAudit = useAuditStore((s) => s.refresh);
  const unregisterProject = useSettingsStore((s) => s.unregisterProject);

  // A scan failure isn't about any one project, so it gets Rescan only —
  // there's no folder to reveal or project to stop tracking.
  const projectRoot =
    problem.scope?.scope === "project" ? problem.scope.root : null;
  const name = problem.scope ? scopeName(problem.scope, among) : "This machine";
  const path = problem.scope ? scopePath(problem.scope) : null;

  return (
    <Card className="border-critical/30 bg-critical/5">
      <CardHeader>
        <CardTitle className="text-base text-critical">
          {PROBLEM_HEADLINES[problem.kind]}
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3">
        <div>
          <p className="break-all text-sm font-medium">{name}</p>
          {path ? (
            <p className="truncate font-mono text-xs text-muted-foreground">
              {path}
            </p>
          ) : null}
        </div>
        <p className="break-words rounded-md bg-muted/50 p-2 font-mono text-xs text-muted-foreground">
          {problem.message}
        </p>
        <ul className="list-disc space-y-1 pl-5 text-xs text-muted-foreground">
          {PROBLEM_STEPS[problem.kind].map((step) => (
            <li key={step}>{step}</li>
          ))}
        </ul>
        <div className="flex flex-wrap gap-2">
          <Button
            size="sm"
            variant="outline"
            onClick={() => {
              void refreshScan();
              void refreshAudit();
            }}
          >
            Rescan
          </Button>
          {projectRoot ? (
            <Button
              size="sm"
              variant="outline"
              onClick={() => void commands.revealPath(projectRoot)}
            >
              Show in file browser
            </Button>
          ) : null}
          {projectRoot ? (
            <Button
              size="sm"
              variant="outline"
              onClick={() => setConfirmRemove(true)}
            >
              Stop tracking this project…
            </Button>
          ) : null}
        </div>
      </CardContent>
      {projectRoot ? (
        <ConfirmDialog
          open={confirmRemove}
          onOpenChange={setConfirmRemove}
          title={`Stop tracking ${name}?`}
          description="kendex will stop managing this project. Nothing in the folder is deleted."
          confirmLabel="Stop tracking"
          destructive
          onConfirm={() => {
            void unregisterProject(projectRoot);
            setConfirmRemove(false);
          }}
        />
      ) : null}
    </Card>
  );
}
