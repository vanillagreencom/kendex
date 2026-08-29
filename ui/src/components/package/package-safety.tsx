import { CircleHelp, TriangleAlert } from "lucide-react";
import type { ItemKind, Scope } from "@/bindings";
import { EmptyState } from "@/components/empty-state";
import {
  type InstalledReading,
  useInstalledReading,
} from "@/components/installed-score";
import { DotSpinner } from "@/components/loading";
import { SafetyPanel } from "@/components/safety-panel";
import { ScoreCircle } from "@/components/score-circle";
import { Button } from "@/components/ui/button";
import {
  SAFETY_CHECK_FAILED,
  SAFETY_CHECKING,
  SAFETY_NOT_READ,
  SAFETY_NOT_READ_BODY,
  SAFETY_RETRY_LABEL,
  SAFETY_TAB,
  severityTone,
} from "@/lib/copy-safety";
import { useAuditOnMount } from "@/stores/audit";

/** The safety reading for the copy installed at the one place this page is
 *  about — not the same name somewhere else on the machine. Asks for a
 *  fresh audit as the page comes up; the store's freshness window decides
 *  whether that costs anything. */
export function usePackageSafety(
  kind: ItemKind,
  name: string,
  scope: Scope,
): InstalledReading {
  useAuditOnMount();
  return useInstalledReading(kind, name, [scope]);
}

/** The tab's name with the score after it. The words come first: the disc
 *  is decorative, so a tab labelled with the figure alone would name a
 *  number and nothing it is a number of. Until a reading arrives the disc
 *  shows a dash rather than a zero, which is a score a package can earn. */
export function SafetyScoreLabel({ reading }: { reading: InstalledReading }) {
  const { result } = reading;
  return (
    <>
      {SAFETY_TAB}
      <ScoreCircle
        size="sm"
        score={result?.safety.score ?? null}
        tone={result ? severityTone(result.findings) : "muted"}
      />
    </>
  );
}

/** What the check made of this package, in full.
 *
 *  Four answers that must never blur: a reading, a check that failed with
 *  nothing kept from a better one, a first check still on its way, and an
 *  audit that answered with no reading for this package at all. A blank
 *  panel for any of the last three would read as a package the check found
 *  nothing in, which is the one claim it has not made. */
export function PackageSafety({ reading }: { reading: InstalledReading }) {
  const retry = (
    <Button variant="outline" onClick={reading.retry}>
      {SAFETY_RETRY_LABEL}
    </Button>
  );
  if (reading.result) {
    return (
      <SafetyPanel
        result={reading.result}
        stale={reading.failure !== null}
        checkedAt={reading.checkedAt}
        onRetry={reading.retry}
      />
    );
  }
  if (reading.failure !== null) {
    return (
      <div className="flex justify-center">
        <EmptyState
          icon={TriangleAlert}
          title={SAFETY_CHECK_FAILED}
          action={retry}
        >
          {reading.failure}
        </EmptyState>
      </div>
    );
  }
  if (reading.waiting) {
    return (
      <p className="flex items-center justify-center gap-2 py-20 text-sm text-muted-foreground">
        <DotSpinner />
        {SAFETY_CHECKING}
      </p>
    );
  }
  return (
    <div className="flex justify-center">
      <EmptyState icon={CircleHelp} title={SAFETY_NOT_READ} action={retry}>
        {SAFETY_NOT_READ_BODY}
      </EmptyState>
    </div>
  );
}
