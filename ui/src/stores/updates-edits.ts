import { toast } from "sonner";
import type { HarnessId, UpdateRow } from "@/bindings";
import { FORK_ERROR_TITLE, forkedToastLabel } from "@/lib/copy";
import {
  installedAsNewToastLabel,
  installedBesideUnfinishedToast,
  UPDATE_NEEDS_CHECK_NOTE,
} from "@/lib/copy-updates";
import { packageDisplayName } from "@/lib/labels";
import { rescanEverything } from "@/lib/rescan";
import { caught } from "@/lib/settled";
import { rowUnsettled } from "@/lib/updates-read-state";
import { useProblemsStore } from "./problems";
import { useUpdatesStore } from "./updates";
import {
  writeDiscardEdits,
  writeFork,
  writeForkBeside,
} from "./updates-writes";

/** The ways out of an edited place, run under the updates store's busy
 *  flag so every control on the page waits on the same one — a fork, a
 *  discard, or an install beside rewrites the scope's manifest like any
 *  update does. Each returns the failure, or what the work answered once
 *  the follow-up refreshes have landed. */

type Outcome<T> = { error: string } | { ok: T };

const run = async <T>(work: () => Promise<Outcome<T>>): Promise<Outcome<T>> => {
  useUpdatesStore.setState({ busy: true });
  try {
    // A transport failure rejects rather than refusing; caught here it is
    // presented as the refusal shape, which claims nothing happened.
    const answer = await caught(work());
    // Whatever the work answered, the standing is read again: it may have
    // committed and then failed, and the rows on screen must be what
    // actually landed.
    await useUpdatesStore.getState().reload();
    if (answer.status === "error") return { error: answer.error };
    if (!("error" in answer.data)) await rescanEverything();
    return answer.data;
  } finally {
    useUpdatesStore.setState({ busy: false });
  }
};

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

/** Keep an edited place's files as a local fork of its own. Only some
 *  tools' renderings read back as source; the row names the edited one a
 *  fork can take, and the button is not offered without it. */
export const keepAsOwn = async (row: UpdateRow): Promise<void> => {
  const harness = row.forkableHarness;
  if (!harness) return;
  report(
    await run(async () => {
      const response = await writeFork(row.scope, row.kind, row.name, harness);
      if (response.status === "error") return { error: response.error };
      toast.success(forkedToastLabel(packageDisplayName(row)));
      return { ok: null };
    }),
  );
};

/** Drop an edited place's edits and take the newest version — moving the
 *  hold along when the place is held, in the same apply. */
export const takeNewVersion = async (row: UpdateRow): Promise<void> => {
  if (stale(row)) {
    report({ error: UPDATE_NEEDS_CHECK_NOTE });
    return;
  }
  report(
    await run(async () => {
      const response = await writeDiscardEdits(
        row.scope,
        row.kind,
        row.name,
        // A held place moves to the newest only when that is its own hold
        // to move and the newest is known; otherwise the discard restores
        // what is resolved now.
        row.pinned && row.canTakeLatest ? (row.latest?.commit ?? null) : null,
      );
      return response.status === "error"
        ? { error: response.error }
        : { ok: null };
    }),
  );
};

/** Keep an edited place's files as the user's own package under `own`,
 *  and let the source's newest version back in under the original name.
 *  `harness` is the edited rendering the row named as forkable. Returns a
 *  refusal — nothing written, another name may go through — for the
 *  dialog to show at the point of action, or null. A fork the scope
 *  recorded but could not render is not a refusal: the dialog closes, the
 *  toast says what landed, and the refreshed rows carry the rest. An
 *  error in neither phase — a transport rejection, a binary older than
 *  this UI — must never read as a recorded fork: it is presented as a
 *  refusal, the shape that claims nothing happened. */
export const installAsNew = async (
  row: UpdateRow,
  harness: HarnessId,
  own: string,
): Promise<string | null> => {
  if (stale(row)) return UPDATE_NEEDS_CHECK_NOTE;
  const name = packageDisplayName(row);
  const outcome = await run<string | null>(async () => {
    const response = await writeForkBeside(
      row.scope,
      row.kind,
      row.name,
      harness,
      own,
      // The same rule as discarding: a held place moves to the newest when
      // that hold is its own to move.
      row.pinned && row.canTakeLatest ? (row.latest?.commit ?? null) : null,
    );
    if (response.status === "ok") return { ok: null };
    const failure: unknown = response.error;
    if (typeof failure === "object" && failure !== null && "phase" in failure) {
      const { phase, message } = failure as { phase: string; message: string };
      if (phase === "recorded") return { ok: message };
      if (phase === "refused") return { error: message };
    }
    return { error: String(failure) };
  });
  if ("error" in outcome) return outcome.error;
  if (outcome.ok === null) toast.success(installedAsNewToastLabel(name, own));
  else toast.info(installedBesideUnfinishedToast(name, own, outcome.ok));
  return null;
};
