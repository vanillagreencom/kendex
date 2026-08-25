import { useMemo } from "react";
import { DotSpinner } from "@/components/loading";
import { SafetyPanel } from "@/components/safety-panel";
import { installedSafety } from "@/lib/installed-safety";
import { useAuditOnMount, useAuditStore } from "@/stores/audit";
import type { PackageRef } from "@/stores/nav";

/** The installed package's safety reading, scored where the files sit.
 *
 *  The audit is the slowest thing the app does, so the page can open before
 *  it has answered. Until it does the block says it is still reading rather
 *  than showing a score it does not have — an absent block would read as
 *  "nothing found", which is the one claim the check has not made yet. */
export function PackageSafety({ reference }: { reference: PackageRef }) {
  useAuditOnMount();
  // Merged out of the store's rows, not selected from them: the merge
  // builds a fresh object every call, and a selector returning one of those
  // would re-render the page against itself forever.
  const views = useAuditStore((s) => s.views);
  const result = useMemo(
    () =>
      installedSafety(views, reference.kind, reference.name, reference.scope),
    [views, reference.kind, reference.name, reference.scope],
  );
  // A failed audit is an answer, not a wait: the Problems footer carries the
  // failure, and this block stands down rather than spinning for the session.
  const answered = useAuditStore((s) => s.auditedAt !== null);
  const failed = useAuditStore((s) => s.checkError !== null);

  if (result) return <SafetyPanel result={result} />;
  if (answered || failed) return null;
  return (
    <p className="flex items-center gap-2 text-sm text-muted-foreground">
      <DotSpinner />
      Checking this package…
    </p>
  );
}
