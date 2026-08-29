import { CircleHelp, Package, TriangleAlert } from "lucide-react";
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
import { vendorHelp } from "@/lib/copy";
import {
  SAFETY_CHECK_FAILED,
  SAFETY_CHECKING,
  SAFETY_NOT_READ,
  SAFETY_NOT_READ_BODY,
  SAFETY_RETRY_LABEL,
  SAFETY_TAB,
  SAFETY_TAB_STALE,
  SAFETY_VENDOR,
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
 *  shows a dash rather than a zero, which is a score a package can earn.
 *
 *  A reading kept from before a failed check is on the tab too, because it
 *  is the last thing anything knows. It stops being drawn as a current
 *  severity: the disc goes muted and the tab carries the mark, so the
 *  figure is not read as a count the check just took. Somebody looking at
 *  Overview sees only this label, and a kept number that looks current
 *  there is a claim nothing on the machine supports. */
export function SafetyScoreLabel({
  reading,
  vendor,
}: {
  reading: InstalledReading;
  vendor: string | null;
}) {
  const { result, failure } = reading;
  // A tool's own content carries no disc at all. The dash reads as a figure
  // still on its way, and for this one nothing is on its way.
  if (vendor) return <>{SAFETY_TAB}</>;
  const current = result !== null && failure === null;
  return (
    <>
      {SAFETY_TAB}
      <ScoreCircle
        size="sm"
        score={result?.safety.score ?? null}
        tone={current ? severityTone(result.findings) : "muted"}
      />
      {result !== null && failure !== null ? (
        <>
          <TriangleAlert className="size-3.5 text-warning" />
          {/* Colour is never the only carrier of the fact. */}
          <span className="sr-only">{SAFETY_TAB_STALE}</span>
        </>
      ) : null}
    </>
  );
}

/** What the check made of this package, in full.
 *
 *  Five answers that must never blur: content the audit does not read at
 *  all, a reading, a check that failed with nothing kept from a better one,
 *  a first check still on its way, and an audit that answered with no
 *  reading for this package. A blank panel for any of them would read as a
 *  package the check found nothing in, which is the one claim it has not
 *  made.
 *
 *  The vendor answer comes first and carries no retry. `observed_rows`
 *  skips content a tool ships itself, so no audit will ever score it, and
 *  the unscored state's button would ask for a check that is not coming. */
export function PackageSafety({
  reading,
  vendor,
}: {
  reading: InstalledReading;
  vendor: string | null;
}) {
  const retry = (
    <Button variant="outline" onClick={reading.retry}>
      {SAFETY_RETRY_LABEL}
    </Button>
  );
  if (vendor) {
    return (
      <div className="flex justify-center">
        <EmptyState icon={Package} title={SAFETY_VENDOR}>
          {vendorHelp(vendor)}
        </EmptyState>
      </div>
    );
  }
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
