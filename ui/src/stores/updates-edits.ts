import { toast } from "sonner";
import { commands, type HarnessId, type UpdateRow } from "@/bindings";
import { FORK_ERROR_TITLE, forkedToastLabel } from "@/lib/copy";
import {
  installedAsNewToastLabel,
  UPDATE_NEEDS_CHECK_NOTE,
} from "@/lib/copy-updates";
import { packageDisplayName } from "@/lib/labels";
import { useAuditStore } from "./audit";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";
import { useUpdatesStore } from "./updates";

/** The ways out of an edited place, run under the updates store's busy
 *  flag so every control on the page waits on the same one — a fork, a
 *  discard, or an install beside rewrites the scope's manifest like any
 *  update does. Each returns the failure, or null once the follow-up
 *  refreshes have landed. */

const run = async (
  work: () => Promise<string | null>,
): Promise<string | null> => {
  useUpdatesStore.setState({ busy: true });
  try {
    // The commit and the overview that follows ride the updates store's
    // side-effect chain, in commit order with every other operation.
    const error = await useUpdatesStore.getState().mutate(work);
    if (error !== null) return error;
    await useScanStore.getState().refresh();
    await useAuditStore.getState().refresh({ force: true });
    return null;
  } finally {
    useUpdatesStore.setState({ busy: false });
  }
};

const report = (error: string | null) => {
  if (error !== null)
    useProblemsStore
      .getState()
      .showError({ title: FORK_ERROR_TITLE, message: error });
};

/** Rows kept from a failed check, or about to be replaced by a running
 *  one, name a `latest` nobody confirmed — an action that may move a hold
 *  to it stops here, whatever the trigger looked like. */
const unsettled = (): boolean => {
  const { loaded, checking, overviewInFlight } = useUpdatesStore.getState();
  return !loaded || checking || overviewInFlight;
};

/** Keep an edited place's files as a local fork of its own. Only some
 *  tools' renderings read back as source; the row names the edited one a
 *  fork can take, and the button is not offered without it. */
export const keepAsOwn = async (row: UpdateRow): Promise<void> => {
  const harness = row.forkableHarness;
  if (!harness) return;
  report(
    await run(async () => {
      const response = await commands.packageFork(
        row.scope,
        row.kind,
        row.name,
        harness,
      );
      if (response.status === "error") return response.error;
      toast.success(forkedToastLabel(packageDisplayName(row)));
      return null;
    }),
  );
};

/** Drop an edited place's edits and take the newest version — moving the
 *  hold along when the place is held, in the same apply. */
export const takeNewVersion = async (row: UpdateRow): Promise<void> => {
  if (unsettled()) {
    report(UPDATE_NEEDS_CHECK_NOTE);
    return;
  }
  report(
    await run(async () => {
      const response = await commands.applyDiscardEdits(
        row.scope,
        row.kind,
        row.name,
        // A held place moves to the newest only when that is its own hold
        // to move and the newest is known; otherwise the discard restores
        // what is resolved now.
        row.pinned && row.canTakeLatest ? (row.latest?.commit ?? null) : null,
      );
      return response.status === "error" ? response.error : null;
    }),
  );
};

/** Keep an edited place's files as the user's own package under `own`,
 *  and let the source's newest version back in under the original name.
 *  `harness` is the edited rendering the row named as forkable. Returns
 *  the refusal for the dialog to show at the point of action, or null. */
export const installAsNew = async (
  row: UpdateRow,
  harness: HarnessId,
  own: string,
): Promise<string | null> => {
  if (unsettled()) return UPDATE_NEEDS_CHECK_NOTE;
  const error = await run(async () => {
    const response = await commands.packageForkBeside(
      row.scope,
      row.kind,
      row.name,
      harness,
      own,
      // The same rule as discarding: a held place moves to the newest when
      // that hold is its own to move.
      row.pinned && row.canTakeLatest ? (row.latest?.commit ?? null) : null,
    );
    return response.status === "error" ? response.error : null;
  });
  if (error === null)
    toast.success(installedAsNewToastLabel(packageDisplayName(row), own));
  return error;
};
