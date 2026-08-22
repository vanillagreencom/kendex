import { toast } from "sonner";
import { commands, type Scope, type UpdateRow } from "@/bindings";
import { forkedToastLabel } from "@/lib/copy";
import { FORK_ERROR_TITLE } from "@/lib/copy-forks";
import { packageDisplayName } from "@/lib/labels";
import { useAuditStore } from "./audit";
import { manifestRewritten } from "./manifest-sync";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";
import { refusesForUnsaved } from "./unsaved-first";
import { useUpdatesStore } from "./updates";

/** The two ways out of an edited place, run under the updates store's
 *  busy flag so every control on the page waits on the same one — a fork
 *  or a discard rewrites the scope's manifest like any update does. */

const run = async (scope: Scope, work: () => Promise<string | null>) => {
  // Both of these rewrite this scope's kendex.toml, which the Customize tab
  // may be holding an older copy of. Saving that copy afterwards would put
  // the pre-fork contents back, and the fork record lives nowhere else.
  if (refusesForUnsaved(scope)) return;
  useUpdatesStore.setState({ busy: true });
  try {
    const error = await work();
    if (error !== null) {
      useProblemsStore
        .getState()
        .showError({ title: FORK_ERROR_TITLE, message: error });
      return;
    }
    // First, before the tables re-read: the manifest is already rewritten,
    // and every await between the write and this is a window where saving
    // the copy in hand puts the pre-fork file back.
    await manifestRewritten(scope);
    // This read follows the write above, so it is not a poll: a check that
    // was already running must not put the pre-fork rows back over it.
    await useUpdatesStore.getState().load({ afterWrite: true });
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
  await run(row.scope, async () => {
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
  await run(row.scope, async () => {
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
