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
// success is not a complete one, and the two paragraphs below say why no
// predicate over the response is allowed to decide it.
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
// editor save, and the audit's item actions — and the read is asked for in a
// `finally`, so a ninth cannot skip it and neither can a throw. The Updates
// page spells the call out instead, running it whatever the apply answered
// as the last step inside its own `holdingBusy`: `updates.ts`'s
// [`updateOne`] and [`updateRows`], `updates-edits.ts`'s `run` and
// `updates-follow.ts`'s [`followSwitch`]. The package page's
// `package-version-actions.ts` `afterChange` makes the same call inside its
// own busy block but does not await it, so nothing holds over the read.
// Between them, `grep -rnE "writingRepo\(|rescanEverything\(" ui/src` is
// the whole set.
//
// The rest of the direct callers are not the writes this rule is about —
// none of them reaches `repo_effects` — and each is right to ask on its own
// terms: the Scan again buttons, because nothing else knows what a person
// changed outside the app; `settings.ts`'s [`setHarnessRoot`] and
// `settings-projects.ts`'s project register and unregister, because moving a
// tool's folder or changing which projects are tracked changes which files
// the scan finds and which scopes the audit reads — not because a write
// might have half-landed. Those three write the settings file and nothing
// else, so one that failed left nothing on disk for a stale page to report,
// and gating them on the answer is correct.
//
// A scope with no view of its own counts zero unmanaged items, which is how
// a project card ends up hiding the only way to the ones it holds — the
// reason the registry writes above rescan at all.
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

// The read behind the writes, and how many of them one read answers for.
//
// A page of writes goes out one at a time — `adopt-all.ts` over every
// unmanaged item, the delete dialog over every scope a package lives in,
// the package page's every-scope toggle — and a machine-wide read per item
// is seconds of work per item, all of it answering the same question. So
// one read runs at a time and exactly one waits behind it: a request that
// arrives under a running read joins the follow-up rather than stacking
// another identical read. A run of writes then pays for as many reads as
// finish alongside it, never one per write.
//
// The guarantee survives that. A read already running may have passed the
// files this write just changed, so it is never handed back as this write's
// answer — the follow-up it joins starts only once that one has finished,
// which is after this write landed.
//
// It survives one level down too, for two of the three legs: the scan store
// and the audit store each hold a queue of this same shape, so a leg that
// finds its own read already out waits and takes a fresh one behind it
// rather than being served the older answer. The provenance join is the
// exception — `reload` has no such queue, and an older join can still land
// over a newer one — tracked as KEN-1183. Neither store's queue can stand in
// for this one: both are asked by background readers and buttons too, and
// this is about the writes.
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
  queued ??= running
    // However the one in front ended. The three reads each report their own
    // failures, so there is nothing here to pass on, and no shipped path
    // rejects at all — both stores go through `settled` and the join
    // catches. Clearing the slot only on fulfilment would nonetheless
    // strand the mechanism this whole change rests on: one rejection and
    // every later write arriving under a running read joins a dead promise
    // and schedules no read of its own, silently, for the session.
    .catch(() => {})
    .then(() => {
      queued = null;
      return start();
    });
  return queued;
};

/** Run a write that reaches `repo_effects` and read the machine again
 *  behind it.
 *
 *  `body` is the caller's whole action, unchanged: the command, its own
 *  busy flag, the toast, the state update, the re-reads it does itself, on
 *  the refusal arm as much as the landing one. Its value is this call's
 *  value.
 *
 *  The read is asked for in a `finally` — so a caller that throws over the
 *  answer, or a transport failure that rejects instead of refusing, leaving
 *  nobody able to say what the engine got as far as, still reads the machine
 *  before the throw goes on up.
 *
 *  Asked for, not waited on. The caller's promise settles on `body`'s own
 *  value, because a caller renders from it: the unsubscribe dialog draws its
 *  refusal beside the button rather than as a toast, and holding that back
 *  through a forced audit left a destructive button live, re-enabled, with
 *  nothing under it saying the last press failed. [`rescansSettled`] is how
 *  a test waits for what no caller waits for. */
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
