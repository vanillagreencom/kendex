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
import { UPDATED_ALL_TOAST, updatedToastLabel } from "@/lib/copy";
import {
  movedDespiteErrorToastLabel,
  needsAttentionToastLabel,
  nothingMovedToastLabel,
  notUpdatedToastLead,
  removedNotReplacedCountToastLabel,
  removedNotReplacedToastLabel,
  updatedCountToastLabel,
  updatedSomeToastLabel,
} from "@/lib/copy-updates";
import { harnessName, packageDisplayName } from "@/lib/labels";
import { packageCount } from "@/lib/update-groups";

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

/** The three dispositions a plan reports for one package, wherever they
 *  are carried: a single-package apply's own answer, or one entry of a
 *  place's batched one. Both say the same thing about one package, and
 *  reading them apart is how two surfaces end up disagreeing. */
export type PackageDispositions = Pick<
  PackageUpdate_Serialize,
  "removed" | "heldBack" | "moved"
>;

/** Read what an apply reported about one package. Every command that
 *  applies a package answers with this record — the update, the batched
 *  update and the version switch alike — so there is no shape here meaning
 *  "it succeeded, ask no further". */
export const outcomeOf = (update: PackageDispositions): UpdateOutcome => {
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

/** The two lines one surface writes about its own action: what it says
 *  when the plan wrote the package, and what it says when the plan wrote
 *  nothing. A version switch and a Follow source flip did something an
 *  update did not — the manifest moved — so the wording is theirs, while
 *  which of the two is said stays here. The partial case is the moved
 *  line with the held tail after it, so no surface spells that one out. */
export type OutcomeLines = { moved: string; stalled: string };

/** How an Update says it, and the default for every other surface. */
export const updateLines = (name: string): OutcomeLines => ({
  moved: updatedToastLabel(name),
  stalled: notUpdatedToastLead(name),
});

/** Toast what the apply did to `name`, in `lines`' wording. */
export const showUpdateOutcome = (
  name: string,
  update: PackageUpdate_Serialize,
  lines: OutcomeLines = updateLines(name),
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
    toast.success(lines.moved);
    return;
  }
  if (outcome.moved) {
    toast.success(needsAttentionToastLabel(lines.moved, outcome.held));
    return;
  }
  toast.info(needsAttentionToastLabel(lines.stalled, outcome.held));
};

/** What a run over several places did: the places it wrote, how many it
 *  held or took away, and how many the pre-filter never offered it. A
 *  place counts in every column it belongs to — a package held in one tool
 *  and trashed in another is both.
 *
 *  The caller owns one of these for the whole run and hands it to
 *  [`applyRows`], so a place that rejects at the transport layer cannot
 *  take what earlier places already committed with it: those applies
 *  happened, and the run has to say so. Every line below is read off this
 *  record and nothing else. */
export type BulkOutcome = {
  ok: boolean;
  moved: UpdateRow[];
  held: number;
  removed: number;
  /** Places with news this run was never offered — edited ones, and kinds
   *  whose update lives elsewhere. */
  skipped: number;
};

/** A fresh record for one run over `skipped` places it will not be asked
 *  to touch. */
export const startBulk = (skipped: number): BulkOutcome => ({
  ok: true,
  moved: [],
  held: 0,
  removed: 0,
  skipped,
});

/** Places this run leaves needing a decision on their own row: the ones it
 *  was never offered, and the ones the plan held back. */
export const needsAttention = (outcome: BulkOutcome): number =>
  outcome.skipped + outcome.held;

/** What a finished bulk update may claim. The all-clear belongs to a run
 *  that left nothing behind and an empty list after it: one that took a
 *  copy away, held a place back, was never offered a place, or failed
 *  somewhere has something to say, and "everything is up to date" would
 *  say the opposite of the line already on screen. */
const bulkUpdateToast = (
  outcome: BulkOutcome,
  remaining: UpdateRow[],
): string => {
  const packages = packageCount(outcome.moved);
  const attention = needsAttention(outcome);
  if (attention > 0) return updatedSomeToastLabel(packages, attention);
  if (outcome.ok && outcome.removed === 0 && remaining.length === 0) {
    return UPDATED_ALL_TOAST;
  }
  if (packages === 1) {
    return updatedToastLabel(packageDisplayName(outcome.moved[0]));
  }
  return updatedCountToastLabel(packages);
};

/** Say what a run over several places did, off the record it kept and
 *  nothing else. A place a conflict held back needs attention on its own
 *  row, exactly like one the pre-filter left out, so the two are counted
 *  together; a place whose copy went to the trash is said on its own,
 *  because no count of what else happened outranks it. A run that moved
 *  nothing never claims a success. */
export const showBulkOutcome = (
  outcome: BulkOutcome,
  remaining: UpdateRow[],
): void => {
  if (outcome.removed > 0) {
    toast.error(removedNotReplacedCountToastLabel(outcome.removed));
  }
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
    toast.success(bulkUpdateToast(outcome, remaining));
    return;
  }
  // Nothing moved, and the removal above has not already said why.
  if (outcome.removed === 0) {
    toast.info(nothingMovedToastLabel(needsAttention(outcome)));
  }
};
