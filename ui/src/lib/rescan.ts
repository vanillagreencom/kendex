// What "everything on the machine, read again" means, in one place.
//
// Two reads stand behind every page: the scan says what is on the machine,
// the audit says what it scored. A refresh of only the first left every
// score on screen answering for content the same call had just re-read — so
// both go together, and neither waits on the other.
//
// A write that changes the bytes either read answers for makes both wrong,
// and this is how they are put right: an install, a package coming current,
// a Follow flip that resolved to a new commit, a registry change. The
// buttons offering to look again run it too, because nothing else knows
// what changed.
//
// A write whose own answer carries both reads back for the surface it
// touched does not need it. The audit's item actions are the case: each
// answers with the scope's fresh view and refreshes the scan itself.
//
// Adding a project, dropping one, or moving a harness's folder changes
// which scopes the audit reads, and a scope with no view of its own counts
// zero unmanaged items — which is how a project card ends up hiding the
// only way to the ones it holds.
import { useAuditStore } from "@/stores/audit";
import { useScanStore } from "@/stores/scan";

export async function rescanEverything(opts?: {
  /** Say so when the scan fails, however many times running. Somebody who
   *  pressed a button is waiting on an answer and hears about it whatever
   *  the last background scan already said; a rescan behind a write is not
   *  waited on, and the scan store's own once-only notice covers it. */
  announce?: boolean;
}): Promise<void> {
  await Promise.all([
    useScanStore.getState().refresh({ announce: opts?.announce === true }),
    // Forced: a write moved the very bytes a score answers for, and the
    // audit's freshness window would otherwise answer from before it.
    useAuditStore.getState().refresh({ force: true }),
  ]);
}
