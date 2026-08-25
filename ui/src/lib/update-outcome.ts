// What one package's Update actually did, said out loud. The plan holds a
// rendering back rather than writing over a copy somebody changed, so
// "Updated" is claimed only about what moved — the Updates page filters
// edited rows before it gets here, the package page does not filter at
// all, and both would otherwise toast success over a package still
// sitting where it was.
import { toast } from "sonner";
import type { HarnessId, PackageUpdate_Serialize, UpdateRow } from "@/bindings";
import { updatedToastLabel } from "@/lib/copy";
import {
  nothingMovedToastLabel,
  notUpdatedToastLabel,
  removedNotReplacedToastLabel,
  updatedExceptToastLabel,
} from "@/lib/copy-updates";
import { harnessName } from "@/lib/labels";
import { bulkUpdateToast } from "@/lib/update-toasts";

/** The tools named by a set of drift rows, each once, in the order they
 *  came back. */
export const toolsOf = (rows: { harness: HarnessId }[]): string[] => [
  ...new Set(rows.map((row) => harnessName(row.harness))),
];

/** Toast what the apply did to `name`: everything moved, some of it moved,
 *  or a conflict held all of it. */
export const showUpdateOutcome = (
  name: string,
  update: PackageUpdate_Serialize,
): void => {
  // Said first and said as an error: a refusal with nothing of the
  // person's to keep takes the copy away and writes nothing back, and no
  // other half of the outcome outranks that.
  const gone = toolsOf(update.removed);
  if (gone.length > 0) {
    toast.error(removedNotReplacedToastLabel(name, gone));
    return;
  }
  const held = toolsOf(update.heldBack);
  if (held.length === 0) {
    toast.success(updatedToastLabel(name));
    return;
  }
  if (update.moved.length > 0) {
    toast.success(updatedExceptToastLabel(name, held));
    return;
  }
  toast.info(notUpdatedToastLabel(name, held));
};

/** Say what a run over several places did. A place a conflict held back
 *  needs attention on its own row, exactly like one the pre-filter left
 *  out, so the two are counted together — and a run that moved nothing
 *  never claims a success. */
export const showBulkOutcome = (
  moved: UpdateRow[],
  attention: number,
  remaining: UpdateRow[],
): void => {
  if (moved.length === 0) {
    toast.info(nothingMovedToastLabel(attention));
    return;
  }
  toast.success(bulkUpdateToast(moved, attention, remaining));
};
