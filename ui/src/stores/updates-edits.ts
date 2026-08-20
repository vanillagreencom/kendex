import { toast } from "sonner";
import { commands, type UpdateRow } from "@/bindings";
import { FORK_ERROR_TITLE, forkedToastLabel } from "@/lib/copy";
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
    const error = await work();
    if (error !== null) {
      useProblemsStore
        .getState()
        .showError({ title: FORK_ERROR_TITLE, message: error });
      return;
    }
    await useUpdatesStore.getState().load();
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
  await run(async () => {
    const response = await commands.applyDiscardEdits(
      row.scope,
      row.kind,
      row.name,
      // A derived place's revision belongs to the bundle or package that
      // pulled it in; only a declared hold can move along with the discard.
      row.pinned && !row.derived ? (row.latest?.commit ?? null) : null,
    );
    return response.status === "error" ? response.error : null;
  });
};
