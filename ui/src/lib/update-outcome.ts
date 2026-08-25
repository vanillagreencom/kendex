// What one package's Update actually did, and how each surface says it.
//
// One classification, read by every surface. The plan holds a rendering
// back rather than writing over a copy somebody changed, and takes one
// with nothing of theirs in it to the trash — three things can happen to a
// package, and a surface that works them out from the payload's shape gets
// the next one wrong. Both the per-row report and the bulk one read
// `outcomeOf`; neither re-derives it.
import { toast } from "sonner";
import type { HarnessId, PackageUpdate_Serialize, UpdateRow } from "@/bindings";
import { updatedToastLabel } from "@/lib/copy";
import {
  movedDespiteErrorToastLabel,
  nothingMovedToastLabel,
  notUpdatedToastLabel,
  removedNotReplacedCountToastLabel,
  removedNotReplacedToastLabel,
  updatedExceptToastLabel,
} from "@/lib/copy-updates";
import { harnessName } from "@/lib/labels";
import { packageCount } from "@/lib/update-groups";
import { bulkUpdateToast } from "@/lib/update-toasts";

/** The tools named by a set of drift rows, each once, in the order they
 *  came back. */
export const toolsOf = (rows: { harness: HarnessId }[]): string[] => [
  ...new Set(rows.map((row) => harnessName(row.harness))),
];

/** What became of one package, described rather than judged: a run can do
 *  more than one of these at once, and a reading that picks a single
 *  verdict drops whichever it did not pick. */
export type UpdateOutcome = {
  /** Tools whose copy went to the trash with nothing written back. */
  removed: string[];
  /** Tools whose copy the plan refused to write and left exactly as it is. */
  held: string[];
  /** Whether the plan wrote this package anywhere at all. */
  moved: boolean;
};

/** Read what a single-package apply reported. `null` is a hold move:
 *  `packageSetRev` answers with the view alone, so it moved on the
 *  strength of the command succeeding — the reading that path has always
 *  had. */
export const outcomeOf = (
  update: PackageUpdate_Serialize | null,
): UpdateOutcome => {
  if (!update) {
    return { removed: [], held: [], moved: true };
  }
  const removed = toolsOf(update.removed);
  const held = toolsOf(update.heldBack);
  return {
    removed,
    held,
    // Nothing refused is nothing in the way: the plan wrote the package.
    moved:
      update.moved.length > 0 || (removed.length === 0 && held.length === 0),
  };
};

/** Toast what the apply did to `name`. */
export const showUpdateOutcome = (
  name: string,
  update: PackageUpdate_Serialize,
): void => {
  const outcome = outcomeOf(update);
  // Said first and said as an error: a refusal with nothing of the
  // person's to keep takes the copy away and writes nothing back, and no
  // other half of the outcome outranks that.
  if (outcome.removed.length > 0) {
    toast.error(removedNotReplacedToastLabel(name, outcome.removed));
    return;
  }
  if (outcome.held.length === 0) {
    toast.success(updatedToastLabel(name));
    return;
  }
  if (outcome.moved) {
    toast.success(updatedExceptToastLabel(name, outcome.held));
    return;
  }
  toast.info(notUpdatedToastLabel(name, outcome.held));
};

/** What a run over several places did: the places it wrote, and how many
 *  it held or took away. A place counts in every column it belongs to — a
 *  package held in one tool and trashed in another is both. */
export type BulkOutcome = {
  ok: boolean;
  moved: UpdateRow[];
  held: number;
  removed: number;
};

/** Say what a run over several places did. A place a conflict held back
 *  needs attention on its own row, exactly like one the pre-filter left
 *  out, so the two are counted together; a place whose copy went to the
 *  trash is said on its own, because no count of what else happened
 *  outranks it. A run that moved nothing never claims a success. */
export const showBulkOutcome = (
  outcome: BulkOutcome,
  skipped: number,
  remaining: UpdateRow[],
): void => {
  if (outcome.removed > 0) {
    toast.error(removedNotReplacedCountToastLabel(outcome.removed));
  }
  const attention = skipped + outcome.held;
  // A place in this run failed. Its error is already on screen, and what
  // the places that did run came to is said beside it — silence here is
  // how a package that went to the trash goes unmentioned because an
  // unrelated row could not be reached.
  if (!outcome.ok) {
    if (outcome.moved.length > 0) {
      toast.info(movedDespiteErrorToastLabel(packageCount(outcome.moved)));
    }
    return;
  }
  if (outcome.moved.length > 0) {
    toast.success(bulkUpdateToast(outcome.moved, attention, remaining));
    return;
  }
  // Nothing moved, and the removal above has not already said why.
  if (outcome.removed === 0) {
    toast.info(nothingMovedToastLabel(attention));
  }
};
