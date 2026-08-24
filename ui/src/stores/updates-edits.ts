import { toast } from "sonner";
import { commands, type UpdateRow } from "@/bindings";
import { FORK_ERROR_TITLE, forkedToastLabel } from "@/lib/copy";
import { UPDATE_NEEDS_CHECK_NOTE } from "@/lib/copy-updates";
import { packageDisplayName } from "@/lib/labels";
import { useAuditStore } from "./audit";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";
import { useUpdatesStore } from "./updates";

/** The two ways out of an edited place, run under the updates store's
 *  busy flag so every control on the page waits on the same one — a fork
 *  or a discard rewrites the scope's manifest like any update does. */

const run = async (work: () => Promise<string | null>) => {
  useUpdatesStore.setState({ busy: true });
  try {
    // The commit and the overview that follows ride the updates store's
    // side-effect chain, in commit order with every other operation.
    const error = await useUpdatesStore.getState().mutate(work);
    if (error !== null) {
      useProblemsStore
        .getState()
        .showError({ title: FORK_ERROR_TITLE, message: error });
      return;
    }
    await useScanStore.getState().refresh();
    await useAuditStore.getState().refresh({ force: true });
  } finally {
    useUpdatesStore.setState({ busy: false });
  }
};

/** Keep an edited place's files as a local fork of its own. Only some
 *  tools' renderings read back as source; the row names the edited one a
 *  fork can take, and the button is not offered without it. */
export const keepAsOwn = async (row: UpdateRow): Promise<void> => {
  const harness = row.forkableHarness;
  if (!harness) return;
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
  });
};

/** Drop an edited place's edits and take the newest version — moving the
 *  hold along when the place is held, in the same apply. */
export const takeNewVersion = async (row: UpdateRow): Promise<void> => {
  // The action boundary owns the guarantee: a confirmation opened before
  // a check failed still holds a retained row, and its latest names a
  // commit nobody confirmed. The trigger gates are UX; this is the stop.
  if (!useUpdatesStore.getState().loaded) {
    useProblemsStore
      .getState()
      .showError({ title: FORK_ERROR_TITLE, message: UPDATE_NEEDS_CHECK_NOTE });
    return;
  }
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
  });
};
