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
// The rule, for every write that reaches `repo_effects`: the machine is read
// again once the write has been answered for, whatever it answered. No
// caller carves itself out — a refusal is not an account of the disk, a
// success is not a complete one, and the two reasons below say why no
// predicate over the response is allowed to decide it. The buttons offering
// to look again call [`rescanEverything`] directly, because nothing else
// knows what changed.
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
// Two spellings carry the rule, and between them they are the set —
// `grep -rnE "writingRepo\(|rescanEverything\(" ui/src` finds every one.
// [`writingRepo`] below is the wrapper: it runs the command, hands the
// answer to the caller, and reads the machine once the caller is done with
// it — which is how the marketplace install, the source toggle, the
// unsubscribe, the editor save and the audit's item actions cannot skip it,
// and how a sixth of them will not either. The Updates page and the package
// page spell it out instead, calling [`rescanEverything`] as the last step
// of a `holdingBusy` block that runs whatever the apply answered:
// `updates.ts`'s [`updateOne`] and [`updateRows`], `updates-edits.ts`'s
// `run`, `updates-follow.ts`'s [`followSwitch`], and
// `package-version-actions.ts`'s `afterChange`.
//
// `settings.ts`'s [`setHarnessRoot`] is the one write that gates on its
// answer and is right to: it saves the settings file and never reaches
// `repo_effects`, so a save that failed left nothing on disk for a stale
// page to report. It rescans on success because moving a tool's folder
// changes which files the scan finds, not because a write might have
// half-landed.
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

/** Run a write that reaches `repo_effects` and read the machine again once
 *  it has been answered for.
 *
 *  `write` makes the call — and holds whatever busy flag its page already
 *  held over it, which is why the flag stays the caller's and is not taken
 *  over here. `answered` gets the answer the moment the engine gives it and
 *  does everything the caller does with it, refusal arm included: the toast,
 *  the state update, its own re-reads. Its value is this call's value, so a
 *  caller reporting a boolean or an outcome object still reports it.
 *
 *  Then [`rescanEverything`], on the rule above: after `answered`, so the
 *  person hears the outcome without waiting on three machine-wide reads, and
 *  in a `finally`, so a caller that throws over the answer — or a transport
 *  failure that rejects instead of refusing, leaving nobody able to say what
 *  the engine got as far as — still reads the machine before the throw goes
 *  on up. */
export async function writingRepo<T, R>(
  write: () => Promise<T>,
  answered: (answer: T) => R | Promise<R>,
): Promise<R> {
  try {
    return await answered(await write());
  } finally {
    await rescanEverything();
  }
}
