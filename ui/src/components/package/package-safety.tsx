import { useInstalledReading } from "@/components/installed-score";
import { DotSpinner } from "@/components/loading";
import { SafetyPanel, SafetyUnavailable } from "@/components/safety-panel";
import { useAuditOnMount } from "@/stores/audit";
import type { PackageRef } from "@/stores/nav";

/** The installed package's safety reading, scored where the files sit.
 *
 *  The audit is the slowest thing the app does, so the page can open before
 *  it has answered. Until it does the block says it is still reading rather
 *  than showing a score it does not have — an absent block would read as
 *  "nothing found", which is the one claim the check has not made yet, and
 *  a check that failed says so with the way to ask again rather than
 *  spinning for the session. */
export function PackageSafety({ reference }: { reference: PackageRef }) {
  useAuditOnMount();
  // This place's copy, not the same name somewhere else on the machine.
  const reading = useInstalledReading(reference.kind, reference.name, [
    reference.scope,
  ]);

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
      <SafetyUnavailable message={reading.failure} onRetry={reading.retry} />
    );
  }
  // Answered with no row for this package is an answer: nothing here is
  // installed where the check could read it.
  if (!reading.waiting) return null;
  return (
    <p className="flex items-center gap-2 text-sm text-muted-foreground">
      <DotSpinner />
      Checking this package…
    </p>
  );
}
