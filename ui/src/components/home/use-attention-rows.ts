import {
  attentionRows,
  updatesIdentity,
} from "@/components/home/attention-rows";
import type { AttentionRow } from "@/components/home/attention-section";
import { availableUpdateCount } from "@/lib/update-groups";
import { rowsCountable } from "@/lib/updates-read-state";
import { useAuditStore } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";
import { useBlockedPlaces, useProblems } from "@/stores/problems";
import { useReadNotices } from "@/stores/read-notices";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";

/** Every attention row, read off the live stores. Home, the status footer
 *  and the Problems page take this, so none of them counts or classifies
 *  the stores on its own. The Updates badge is not a row and reads the
 *  update store and the updates read slot itself. */
export function useAttentionRows(): AttentionRow[] {
  const problems = useProblems();
  const blocked = useBlockedPlaces();
  const result = useScanStore((s) => s.result);
  // The audit read's own outcome, which is the only thing its row may
  // speak for: a failed remove or adopt is not a failed audit, and reaches
  // the person through the problems dialog instead.
  const auditError = useAuditStore((s) => s.read.error);
  const auditRefresh = useAuditStore((s) => s.refresh);
  const updateRows = useUpdatesStore((s) => s.rows);
  const updatesError = useUpdatesStore((s) => s.read.error);
  // The rows survive a failed re-check as last-known facts, which is enough
  // for the edited row and not enough for a number — [rowsCountable] is the
  // one rule for that difference. Counted as updates and not as news: the
  // sidebar's badge stands for the Updates page's whole list, this row's
  // words promise an update to take.
  const updates = useUpdatesStore((s) =>
    rowsCountable(s) ? availableUpdateCount(s.rows) : null,
  );
  const unreadable = useUpdatesStore((s) => s.unreadable);
  const read = useReadNotices((s) => s.read);
  const goTo = useNavStore((s) => s.goTo);
  const setPage = useNavStore((s) => s.setPage);
  const goToLibrary = useNavStore((s) => s.goToLibrary);
  const goToPackage = useNavStore((s) => s.goToPackage);

  return attentionRows({
    problems,
    blocked,
    // Rows kept from before a failed re-check are last-known, still worth a
    // line; the failure itself gets its own row, so their absence never has
    // to stand in for "couldn't check".
    editedPackages: updateRows.filter((row) => row.blockedByLocalEdit),
    missingPackages: updateRows.filter((row) => row.filesMissing),
    result,
    updatesError,
    updates,
    updatesIdentity: updatesIdentity(updateRows),
    unreadable,
    auditError,
    read,
    onProjects: () => goTo("projects"),
    onProblems: () => goTo("problems"),
    onUpdates: () => setPage("updates"),
    onEditedPackages: () => goToLibrary({ edited: true }),
    // The installed list, unnarrowed: each row marks the places missing a
    // file, and the attention row already named them.
    onMissingPackages: () => goToLibrary({}),
    onPackage: (row) =>
      // An attention row is built from the update read, which speaks
      // declared packages.
      goToPackage({
        kind: row.kind,
        name: row.name,
        scope: row.scope,
        identity: "recorded",
      }),
    onAuditRetry: () => void auditRefresh({ force: true }),
  });
}
