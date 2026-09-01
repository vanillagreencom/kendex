// Every write of the update standing, and the account each one gives.
//
// The account lives here rather than beside each caller because of what it
// is for: a removal that ran an uninstaller in somebody's repository has to
// be reported by whatever command took the package away. A rule that each
// new mutation remembers to announce is a rule that gets forgotten — it
// was, for a whole round, with one of five paths wired.
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
import { saying } from "@/lib/undone";
import type { BulkOutcome } from "@/lib/update-outcome";
import { type ApplyOutcome, applyRow, applyRows } from "./updates-apply";

/** Await a write and say whatever account its answer carries. */
const announcing = async <T>(work: Promise<T>): Promise<T> =>
  saying(await work);

type Report = (error: string) => void;

/** Bring one place current. */
export const writeRow = (
  row: UpdateRow,
  report: Report,
): Promise<ApplyOutcome> => announcing(applyRow(row, report));

/** Bring every place in `rows` current, one apply per place. */
export const writeRows = (
  rows: UpdateRow[],
  report: Report,
  outcome: BulkOutcome,
): Promise<void> => announcing(applyRows(rows, report, outcome));

/** Mute or unmute a package's update notices. Answers with the overview it
 *  rebuilt after the write. */
export const writeIgnored = (row: UpdateRow, ignored: boolean) =>
  announcing(
    commands.updateSetIgnored(row.scope, row.kind, row.name, row.repo, ignored),
  );

/** Move a package's hold, or let it follow its source again. */
export const writeRev = (
  scope: Scope,
  kind: ItemKind,
  name: string,
  rev: string | null,
) => announcing(commands.packageSetRev(scope, kind, name, rev));

/** Bring one package current where it is installed. */
export const writeUpdate = (scope: Scope, kind: ItemKind, name: string) =>
  announcing(commands.packageUpdate(scope, kind, name));

/** Keep an edited place's files as a fork of its own. */
export const writeFork = (
  scope: Scope,
  kind: ItemKind,
  name: string,
  harness: HarnessId,
) => announcing(commands.packageFork(scope, kind, name, harness));

/** Drop an edited place's edits, moving its hold along where it has one. */
export const writeDiscardEdits = (
  scope: Scope,
  kind: ItemKind,
  name: string,
  rev: string | null,
) => announcing(commands.applyDiscardEdits(scope, kind, name, rev));

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
  announcing(commands.packageForkBeside(scope, kind, name, harness, own, rev));
