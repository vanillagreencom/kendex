// Every write of the update standing, and the count that says one has
// happened.
//
// The count lives here rather than beside each caller because of what it is
// for: an answer built before a commit must not claim to be newer than it,
// and the operations that commit are the ones that have to say so. A rule
// that each new mutation remembers to announce is a rule that gets
// forgotten — it was, for a whole round, with only one of five paths wired.
//
// So the announcement rides on the write itself. A path that goes through
// this module cannot skip it, and a path that does not go through this
// module is one `grep -rn "commands\\." stores/` finds.
import {
  commands,
  type HarnessId,
  type ItemKind,
  type Scope,
  type UpdateRow,
} from "@/bindings";
import { invalidations } from "@/lib/read-state";
import { saying } from "@/lib/undone";
import type { BulkOutcome } from "@/lib/update-outcome";
import { type ApplyOutcome, applyRow, applyRows } from "./updates-apply";

/** Writes that have committed. Read by `updates-standing.ts`, which refuses
 *  a landing-time rank to any answer built before the latest one. */
export const commits = invalidations();

/** Await a write and say a commit may have happened, however it ended.
 *
 *  However it ended, on purpose: the plan writes before it answers, so a
 *  refusal is not proof that nothing landed, and a rejection is proof of
 *  nothing at all. Over-announcing costs an answer its landing-time rank,
 *  which its caller can recover with an ordinary read; under-announcing
 *  lets a stale report overwrite a commit. */
const committing = async <T>(work: Promise<T>): Promise<T> => {
  try {
    // Said on the write for the same reason the commit is announced on it:
    // a removal that ran an uninstaller in somebody's repository has to be
    // reported by whatever command took the package away, and a rule each
    // new mutation remembers is the rule this module already watched get
    // forgotten. A write whose answer carries no account says nothing.
    return saying(await work);
  } finally {
    commits.moved();
  }
};

type Report = (error: string) => void;

/** Bring one place current. */
export const writeRow = (
  row: UpdateRow,
  report: Report,
): Promise<ApplyOutcome> => committing(applyRow(row, report));

/** Bring every place in `rows` current, one apply per place. */
export const writeRows = (
  rows: UpdateRow[],
  report: Report,
  outcome: BulkOutcome,
): Promise<void> => committing(applyRows(rows, report, outcome));

/** Mute or unmute a package's update notices. Answers with the overview it
 *  rebuilt after the write. */
export const writeIgnored = (row: UpdateRow, ignored: boolean) =>
  committing(
    commands.updateSetIgnored(row.scope, row.kind, row.name, row.repo, ignored),
  );

/** Move a package's hold, or let it follow its source again. */
export const writeRev = (
  scope: Scope,
  kind: ItemKind,
  name: string,
  rev: string | null,
) => committing(commands.packageSetRev(scope, kind, name, rev));

/** Bring one package current where it is installed. */
export const writeUpdate = (scope: Scope, kind: ItemKind, name: string) =>
  committing(commands.packageUpdate(scope, kind, name));

/** Keep an edited place's files as a fork of its own. */
export const writeFork = (
  scope: Scope,
  kind: ItemKind,
  name: string,
  harness: HarnessId,
) => committing(commands.packageFork(scope, kind, name, harness));

/** Drop an edited place's edits, moving its hold along where it has one. */
export const writeDiscardEdits = (
  scope: Scope,
  kind: ItemKind,
  name: string,
  rev: string | null,
) => committing(commands.applyDiscardEdits(scope, kind, name, rev));

/** Keep an edited place's files under a new name, and let the source's
 *  newest version back in under the original. */
export const writeForkBeside = (
  scope: Scope,
  kind: ItemKind,
  name: string,
  harness: HarnessId,
  own: string,
  rev: string | null,
) =>
  committing(commands.packageForkBeside(scope, kind, name, harness, own, rev));
