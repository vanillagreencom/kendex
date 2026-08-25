// What one package's Update actually did, said out loud. The plan holds a
// rendering back rather than writing over a copy somebody changed, so
// "Updated" is claimed only about what moved — the Updates page filters
// edited rows before it gets here, the package page does not filter at
// all, and both would otherwise toast success over a package still
// sitting where it was.
import { toast } from "sonner";
import type { HarnessId, PackageUpdate_Serialize } from "@/bindings";
import { updatedToastLabel } from "@/lib/copy";
import {
  notUpdatedToastLabel,
  updatedExceptToastLabel,
} from "@/lib/copy-updates";
import { harnessName } from "@/lib/labels";

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
