// What "everything on the machine, read again" means, in one place.
//
// Three reads stand behind every page: the scan says what is on the machine,
// the audit says what it scored, and the provenance join says where each
// installation came from. A refresh of only the first left every score on
// screen answering for content the same call had just re-read — so they go
// together, and none waits on another.
//
// The join was left out of this for a long time, and every reader of it grew
// its own guess at when to re-read. Those guesses are proxies for "something
// installed" and each one has been wrong about a route somebody later found:
// an install redirected into another project writes its rows under the
// destination's key, so a page watching its own rows sees nothing happen.
// The join belongs here instead, where every write that already says "read
// the machine again" refreshes it, including routes nobody has thought of.
//
// Call it after a write none of those reads has seen: an install, a
// package coming current, a registry change. The buttons offering to look
// again call it because nothing else knows what changed.
//
// The audit's item actions do not: each answers with the scope's fresh view
// and refreshes the scan itself. The Follow-source flip does — it runs the
// same apply an update does, so the bytes both reads answer for move under
// it — and calls this once its own standing has landed.
//
// The writes on the Updates page and the package page call this whatever
// their write answered: `updates.ts`'s [`updateOne`] and [`updateRows`],
// `updates-edits.ts`'s `run`, `updates-follow.ts`'s [`followSwitch`], and
// `package-version-actions.ts`'s `afterChange`. The reasoning lives here
// rather than at each of them.
//
// A refusal is no account of what is on disk. `repo_effects::execute` runs
// the leaving packages' uninstallers before the plan, so an `Undo` error
// comes back with what they did standing and the plan — manifest save
// included — never run; a plan that does run and then fails rolls back
// whole, `run_journaled` restoring every path it touched; and an error can
// come back over a write that committed in full. The answer does not say
// which happened.
//
// Nor is a success a complete account: `moved` covers the two states
// `moving` counts, `removed` the other destructive one, and a dropped
// rendering can answer with all three fields empty. So no predicate over
// the response decides this, and a write that moved nothing pays one scan
// and one forced audit rather than leaving a dated page.
//
// This speaks only for those five. The marketplace, source-toggle and
// settings callers still return on the error before reaching here; whether
// that is right is their own question.
//
// Adding a project, dropping one, or moving a harness's folder changes
// which scopes the audit reads, and a scope with no view of its own counts
// zero unmanaged items — which is how a project card ends up hiding the
// only way to the ones it holds.
import { useAuditStore } from "@/stores/audit";
import { useProvenanceStore } from "@/stores/provenance";
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
    // Answers false rather than throwing, and nothing here acts on the
    // answer: a join that could not be read is the previous rows staying
    // put, which is what every reader already handles.
    useProvenanceStore.getState().reload(),
  ]);
}
