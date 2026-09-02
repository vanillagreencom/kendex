import { toast } from "sonner";
import { commands, type HarnessId, type UpdateRow } from "@/bindings";
import { FORK_ERROR_TITLE, forkedToastLabel } from "@/lib/copy";
import {
  installedAsNewToastLabel,
  installedBesideUnfinishedToast,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_ONE_AT_A_TIME_NOTE,
} from "@/lib/copy-updates";
import { packageDisplayName } from "@/lib/labels";
import { rescanEverything } from "@/lib/rescan";
import { caught } from "@/lib/settled";
import { saying } from "@/lib/undone";
import { rowUnsettled, workOut } from "@/lib/updates-read-state";
import { useProblemsStore } from "./problems";
import { holdingBusy, useUpdatesStore } from "./updates";

/** The ways out of an edited place, run under the updates store's busy
 *  flag so every control on the page waits on the same one — a fork, a
 *  discard, or an install beside rewrites the scope's manifest like any
 *  update does. Each returns the failure, or what the work answered once
 *  the follow-up refreshes have landed. */

type Outcome<T> = { error: string } | { ok: T };

/** Run one way out of an edited place under the updates store's busy, and
 *  hand `say` the outcome the moment the engine answers — ahead of the two
 *  reads behind it. The returned promise covers those reads, which run on
 *  inside the same busy window so no other control acts over them.
 *
 *  Answering first is the point. The engine's word is final by then, and
 *  the reads take seconds: a forced audit deliberately skips its freshness
 *  window. `installAsNew`'s refusal is the dialog's own inline "that name
 *  will not go through" — reported after a machine-wide scan, it is
 *  seconds of a silent dialog over an answer that was already in hand. The
 *  siblings on this path all report first and read after. */
const run = <T>(
  work: () => Promise<Outcome<T>>,
  say: (outcome: Outcome<T>) => void,
): Promise<void> =>
  holdingBusy(async () => {
    // A transport failure rejects rather than refusing; caught here it is
    // presented as the refusal shape, which claims nothing happened.
    const answer = await caught(work());
    say(answer.status === "error" ? { error: answer.error } : answer.data);
    // Whatever the work answered, the standing is read again: it may have
    // committed and then failed, and the rows on screen must be what
    // actually landed.
    await useUpdatesStore.getState().reload();
    // Then the machine, on `rescan.ts`'s rule: asked whatever the work
    // answered, and inside the busy this wrapper holds.
    await rescanEverything();
  });

const report = (outcome: Outcome<unknown>) => {
  if ("error" in outcome)
    useProblemsStore
      .getState()
      .showError({ title: FORK_ERROR_TITLE, message: outcome.error });
};

/** Rows kept from a failed check, about to be replaced by a running one,
 *  or waiting on a follow switch settling in their scope name a `latest`
 *  nobody confirmed — an action that may move a hold to it stops here,
 *  whatever the trigger looked like. */
const stale = (row: UpdateRow): boolean =>
  rowUnsettled(useUpdatesStore.getState(), row);

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
  if (running()) {
    report({ error: UPDATES_ONE_AT_A_TIME_NOTE });
    return;
  }
  await run(async () => {
    const response = saying(
      await commands.packageFork(row.scope, row.kind, row.name, harness),
    );
    if (response.status === "error") return { error: response.error };
    toast.success(forkedToastLabel(packageDisplayName(row)));
    return { ok: null };
  }, report);
};

/** Drop an edited place's edits and take the newest version — moving the
 *  hold along when the place is held, in the same apply. */
export const takeNewVersion = async (row: UpdateRow): Promise<void> => {
  if (running()) {
    report({ error: UPDATES_ONE_AT_A_TIME_NOTE });
    return;
  }
  if (stale(row)) {
    report({ error: UPDATE_NEEDS_CHECK_NOTE });
    return;
  }
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
    return response.status === "error"
      ? { error: response.error }
      : { ok: null };
  }, report);
};

/** Keep an edited place's files as the user's own package under `own`,
 *  and let the source's newest version back in under the original name.
 *  `harness` is the edited rendering the row named as forkable.
 *
 *  `answered` is handed the refusal — nothing written, another name may go
 *  through — for the dialog to show at the point of action, or null when
 *  the dialog should close. It fires at the engine's answer, ahead of the
 *  reads the returned promise covers, because the person's next move is to
 *  retype the name over it. A fork the scope recorded but could not render
 *  is not a refusal: the dialog closes, the toast says what landed, and the
 *  refreshed rows carry the rest. An error in neither phase — a transport
 *  rejection, a binary older than this UI — must never read as a recorded
 *  fork: it is presented as a refusal, the shape that claims nothing
 *  happened. */
export const installAsNew = async (
  row: UpdateRow,
  harness: HarnessId,
  own: string,
  answered: (refusal: string | null) => void,
): Promise<void> => {
  if (running()) return answered(UPDATES_ONE_AT_A_TIME_NOTE);
  if (stale(row)) return answered(UPDATE_NEEDS_CHECK_NOTE);
  const name = packageDisplayName(row);
  await run<string | null>(
    async () => {
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
      if (response.status === "ok") return { ok: null };
      const failure: unknown = response.error;
      if (
        typeof failure === "object" &&
        failure !== null &&
        "phase" in failure
      ) {
        const { phase, message } = failure as {
          phase: string;
          message: string;
        };
        if (phase === "recorded") return { ok: message };
        if (phase === "refused") return { error: message };
      }
      return { error: String(failure) };
    },
    (outcome) => {
      if ("error" in outcome) return answered(outcome.error);
      if (outcome.ok === null)
        toast.success(installedAsNewToastLabel(name, own));
      else toast.info(installedBesideUnfinishedToast(name, own, outcome.ok));
      answered(null);
    },
  );
};
