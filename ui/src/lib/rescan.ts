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
// caller carves itself out, for the two reasons below.
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
// the response decides this, and a write that moved nothing pays one read
// rather than leaving a dated page.
//
// [`writingRepo`] carries the rule: a write that reaches `repo_effects` runs
// its whole body inside it — the marketplace subscribe, install, repository
// effect, source toggle and unsubscribe, the drift-report install, the
// editor save, and the audit's item actions — so a ninth cannot skip it.
// The Updates page spells the call out instead, as the last step inside its
// own `holdingBusy`: `updates.ts`'s [`updateOne`] and [`updateRows`],
// `updates-edits.ts`'s `run` and `updates-follow.ts`'s [`followSwitch`].
// The package page's `package-version-actions.ts` `afterChange` makes the
// same call inside its busy block without awaiting it, so nothing holds
// over the read. `grep -rnE "writingRepo\(|rescanEverything\(" ui/src` is
// the whole set.
//
// The rest of the direct callers are not the writes this rule is about:
// none of them reaches `repo_effects`. The Scan again buttons ask because
// nothing else knows what a person changed outside the app;
// `settings.ts`'s [`setHarnessRoot`] and `settings-projects.ts`'s project
// register and unregister because moving a tool's folder or changing which
// projects are tracked changes which files the scan finds and which scopes
// the audit reads. Those three write the settings file and nothing else, so
// gating them on the answer is correct.
//
// A scope with no view of its own counts zero unmanaged items, which is how
// a project card ends up hiding the only way to the ones it holds — the
// reason the registry writes above rescan at all.
import { useAuditStore } from "@/stores/audit";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";

export async function rescanEverything(opts?: {
  /** Say so when the scan fails, however many times running. Somebody who
   *  pressed a button is waiting on an answer, so a scan this starts speaks
   *  and one it joins re-opens the notice. A rescan behind a write is not
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

// The read behind the writes. One runs at a time and exactly one waits: a
// request arriving under a running read joins that follow-up, which starts
// only once the running one has finished — so every write is answered by a
// read that began after it, and a page of writes does not pay a whole-machine
// read each. The scan and audit stores hold a queue of this shape for their
// own leg; the provenance join has none, so an older join can still land
// over a newer one — KEN-1183.
let running: Promise<void> | null = null;
let queued: Promise<void> | null = null;

const start = (): Promise<void> => {
  const run = rescanEverything().finally(() => {
    if (running === run) running = null;
  });
  running = run;
  return run;
};

const readBehindWrites = (): Promise<void> => {
  if (!running) return start();
  queued ??= running.then(() => {
    queued = null;
    return start();
  });
  return queued;
};

/** Run a write that reaches `repo_effects` and read the machine again
 *  behind it.
 *
 *  `body` is the caller's whole action unchanged — the command, its own busy
 *  flag, the toast, the state update, its own re-reads — on the refusal arm
 *  as much as the landing one, and its value is this call's value.
 *
 *  The read is asked for in a `finally`, so neither a caller throwing over
 *  the answer nor a transport failure rejecting instead of refusing can skip
 *  it. It is not awaited: the caller's promise settles on `body`'s value,
 *  because a caller renders from it — the unsubscribe dialog draws its
 *  refusal beside the button, and holding that back through a forced audit
 *  left a destructive button live with nothing under it. So no hold covers
 *  the read, and every busy window stays where its caller had it.
 *  [`rescansSettled`] is how a test waits for what no caller waits for. */
export async function writingRepo<R>(body: () => Promise<R>): Promise<R> {
  try {
    return await body();
  } finally {
    void readBehindWrites();
  }
}

/** Settle when no read behind a write is left outstanding. For tests: the
 *  reads are deliberately not on any caller's promise, so nothing else in a
 *  test can say when they have landed. */
export async function rescansSettled(): Promise<void> {
  for (let out = queued ?? running; out; out = queued ?? running) await out;
}
