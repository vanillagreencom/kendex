import { toast } from "sonner";
import {
  commands,
  type HarnessId,
  type ItemWarning,
  type UpdateRow,
} from "@/bindings";
import {
  FORK_ERROR_TITLE,
  forkedToastLabel,
  UNKNOWN_COMPLETION_STEP,
  unknownCompletionTitle,
} from "@/lib/copy";
import {
  besideNotInstalledTitle,
  besideRecordedStep,
  installedAsNewToastLabel,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_ONE_AT_A_TIME_NOTE,
} from "@/lib/copy-updates";
import { packageDisplayName } from "@/lib/labels";
import { landingStop } from "@/lib/landing-stopped";
import { beforeWriting, offerToCommit, rescanEverything } from "@/lib/rescan";
import { NO_REASON_GIVEN } from "@/lib/settled";
import { saying, sayUnfinished, sayWritten } from "@/lib/undone";
import { readUnsettled, workOut } from "@/lib/updates-read-state";
import { useProblemsStore } from "./problems";
import { holdingBusy, useUpdatesStore } from "./updates";

/** The ways out of an edited place, run under the updates store's busy
 *  flag so every control on the page waits on the same one — a fork, a
 *  discard, or an install beside rewrites the scope's manifest like any
 *  update does. Each returns the failure, or what the work answered once
 *  the follow-up refreshes have landed. */

/** What the work answered: a refusal, or what it landed. */
type Outcome<T> = { error: string } | { ok: T };

/** The work never rejects: the bindings answer a transport failure as the
 *  command's own error, so whatever went wrong arrives as `work`'s answer. */
const run = <A>(work: () => Promise<A>): Promise<A> =>
  holdingBusy(async () => {
    // Before the work: the offer at the end is about what this action did,
    // and that is a comparison against how the projects stood before it.
    const roots = await beforeWriting();
    const answer = await work();
    // Whatever the work answered, the standing is read again: it may have
    // committed and then failed, and the rows on screen must be what
    // actually landed.
    await useUpdatesStore.getState().reload();
    // Then the machine, on `rescan.ts`'s rule: asked whatever the work
    // answered, and inside the busy this wrapper holds.
    await rescanEverything({ updates: "caller-owned" });
    void offerToCommit(roots);
    return answer;
  });

/** Say a refusal. A fork's and a discard's refusal is a bare string, which
 *  a transport failure is too: nothing tells the two apart, so both read
 *  as the refusal they look like. */
const report = (outcome: Outcome<unknown>) => {
  if ("error" in outcome)
    useProblemsStore
      .getState()
      .showError({ title: FORK_ERROR_TITLE, message: outcome.error });
};

/** Rows kept from a failed check, or about to be replaced by a running
 *  one, name a `latest` nobody confirmed — an action that may move a hold
 *  to it stops here, whatever the trigger looked like. */
const stale = (): boolean => readUnsettled(useUpdatesStore.getState());

/** Whether a check or another write is already out — what bars a commit
 *  when nothing is wrong with the row itself. */
const running = (): boolean => workOut(useUpdatesStore.getState());

/** Keep an edited place using the engine-projected forkable rendering. */
export const keepAsOwn = async (row: UpdateRow): Promise<void> => {
  const harness = row.forkableHarness;
  if (!harness) return;
  // The fork copies what is on disk and reads nothing off the row, so
  // `stale` is its siblings' predicate and not this one's: rows a failed
  // check left behind are still perfectly good to fork from, and that is
  // the state most in need of the way out. What does bar it is that it
  // commits — a check out has a report built before that commit which
  // would land after it.
  const name = packageDisplayName(row);
  if (running()) {
    report({ error: UPDATES_ONE_AT_A_TIME_NOTE });
    return;
  }
  report(
    await run(async () => {
      const response = saying(
        await commands.packageFork(row.scope, row.kind, row.name, harness),
      );
      if (response.status === "error") return { error: response.error };
      toast.success(forkedToastLabel(name));
      sayUnfinished(name, response.data.unfinished);
      sayWritten(response.data.written);
      return { ok: null };
    }),
  );
};

/** Drop an edited place's edits and take the newest version — moving the
 *  hold along when the place is held, in the same apply. */
export const takeNewVersion = async (row: UpdateRow): Promise<void> => {
  const name = packageDisplayName(row);
  if (running()) {
    report({ error: UPDATES_ONE_AT_A_TIME_NOTE });
    return;
  }
  if (stale()) {
    report({ error: UPDATE_NEEDS_CHECK_NOTE });
    return;
  }
  report(
    await run(async () => {
      const response = saying(
        await commands.applyDiscardEdits(
          row.scope,
          row.kind,
          row.name,
          // A held place moves to the newest only when that is its own hold
          // to move and the newest is known; otherwise the discard restores
          // what is resolved now.
          row.pinned && row.canTakeLatest ? (row.latest?.commit ?? null) : null,
        ),
      );
      if (response.status === "error") return { error: response.error };
      sayUnfinished(name, response.data.unfinished);
      return { ok: null };
    }),
  );
};

/** What an install beside landed: the whole of it, with the step behind it
 *  that failed where one did, or only the fork's record. */
type Beside =
  | {
      phase: "installed";
      unfinished: string | null | undefined;
      written: ItemWarning[] | undefined;
    }
  | { phase: "recorded"; why: string; written: ItemWarning[] | undefined };

/** What an install beside answered: a refusal, what it landed, or nothing
 *  at all. Its refusal is typed, so a bare string is the call failing on
 *  its way, and nothing says whether the write ran. */
type BesideOutcome = Outcome<Beside> | { unknown: string };

/** Keep an edited place's files as the user's own package under `own`,
 *  and let the source's newest version back in under the original name.
 *  `harness` is the edited rendering the row named as forkable. Returns a
 *  refusal — nothing written, another name may go through — for the
 *  dialog to show at the point of action, or null. A fork the scope
 *  recorded but could not render is not a refusal: the dialog closes, the
 *  error dialog alone says what did not install and what landed, and the
 *  refreshed rows carry the rest.
 *
 *  An unknown stop ([landingStop]) is the call failing on its way, not the
 *  engine answering: the write may have run, and another name sent over one
 *  that did would install the package a second time. The dialog closes and
 *  the error dialog says nothing is known, over the rows read again behind
 *  it. */
export const installAsNew = async (
  row: UpdateRow,
  harness: HarnessId,
  own: string,
): Promise<string | null> => {
  if (running()) return UPDATES_ONE_AT_A_TIME_NOTE;
  if (stale()) return UPDATE_NEEDS_CHECK_NOTE;
  const name = packageDisplayName(row);
  const outcome = await run(async (): Promise<BesideOutcome> => {
    const response = saying(
      await commands.packageForkBeside(
        row.scope,
        row.kind,
        row.name,
        harness,
        own,
        // The same rule as discarding: a held place moves to the newest when
        // that hold is its own to move.
        row.pinned && row.canTakeLatest ? (row.latest?.commit ?? null) : null,
      ),
    );
    if (response.status === "ok")
      return {
        ok: {
          phase: "installed",
          unfinished: response.data.unfinished,
          written: response.data.written,
        },
      };
    const stop = landingStop(response.error);
    switch (stop.phase) {
      case "refused":
        return { error: stop.message };
      case "recorded":
        return {
          ok: { phase: "recorded", why: stop.message, written: stop.written },
        };
      case "unknown":
        return { unknown: stop.message };
    }
  });
  if ("error" in outcome) return outcome.error;
  if ("unknown" in outcome) {
    useProblemsStore.getState().showError({
      title: unknownCompletionTitle(name),
      message: outcome.unknown,
      steps: [UNKNOWN_COMPLETION_STEP],
    });
    return null;
  }
  switch (outcome.ok.phase) {
    case "installed":
      toast.success(installedAsNewToastLabel(name, own));
      sayUnfinished(name, outcome.ok.unfinished);
      sayWritten(outcome.ok.written);
      return null;
    case "recorded":
      // Not `sayUnfinished`: its step says the change is in place, and the
      // change asked for here is the install that failed. One dialog says
      // the failure, so the lasting account is the only one. The links the
      // recorded fork kept are its capture's own report, not that failure,
      // and nothing read afterwards can say them.
      useProblemsStore.getState().showError({
        title: besideNotInstalledTitle(name),
        message: outcome.ok.why === "" ? NO_REASON_GIVEN : outcome.ok.why,
        steps: [besideRecordedStep(own)],
      });
      sayWritten(outcome.ok.written);
      return null;
  }
};
