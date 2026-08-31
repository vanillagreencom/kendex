import { useState } from "react";
import { commands } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { PlaceCard } from "@/components/place-card";
import { Button } from "@/components/ui/button";
import { PROBLEM_HEADLINES, PROBLEM_STEPS } from "@/lib/error-copy";
import { scopeName, scopePath } from "@/lib/labels";
import { rescanEverything } from "@/lib/rescan";
import type { Problem } from "@/stores/problems";
import { useSettingsStore } from "@/stores/settings";

export function ProblemCard({ problem }: { problem: Problem }) {
  const [confirmRemove, setConfirmRemove] = useState(false);
  const unregisterProject = useSettingsStore((s) => s.unregisterProject);

  // A scan failure isn't about any one project, so it gets Rescan only —
  // there's no folder to reveal or project to stop tracking.
  const projectRoot =
    problem.scope?.scope === "project" ? problem.scope.root : null;
  const name = problem.scope ? scopeName(problem.scope) : "This machine";
  const path = problem.scope ? scopePath(problem.scope) : null;

  return (
    <PlaceCard
      tone="critical"
      headline={PROBLEM_HEADLINES[problem.kind]}
      name={name}
      path={path}
    >
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
          onClick={() => void rescanEverything({ announce: true })}
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
    </PlaceCard>
  );
}
