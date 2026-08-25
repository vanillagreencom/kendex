// What "Scan again" means, in one place.
//
// Two reads stand behind every page: the scan says what is on the machine,
// the audit says what it scored. A button that refreshed only the first
// left every score on screen answering for content the same click had just
// re-read — so both go together, and neither waits on the other.
//
// The settings store's registry writes run through here for the same
// reason: adding a project, dropping one, or moving a harness's folder
// changes which scopes the audit reads, and a scope with no view of its own
// counts zero unmanaged items — which is how a project card ends up hiding
// the only way to the ones it holds.
import { useAuditStore } from "@/stores/audit";
import { useScanStore } from "@/stores/scan";

export async function rescanEverything(): Promise<void> {
  await Promise.all([
    useScanStore.getState().refresh({ announce: true }),
    // Forced: the person asking has a reason to think something changed,
    // and the audit's freshness window would otherwise answer from before
    // whatever that was.
    useAuditStore.getState().refresh({ force: true }),
  ]);
}
