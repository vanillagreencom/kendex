// How rows come current: a held place moves its hold, a following place
// runs the single-package apply — both scoped to the package, so a place's
// Update does not move that scope's other followers (bar one the lock
// cannot place, which resolves fresh either way). Kept beside the store
// the way its read landing and edit flows are, so the store body stays the
// state lifecycle.
import {
  commands,
  type PackageUpdate_Serialize,
  type UpdateRow,
} from "@/bindings";
import { type BulkOutcome, outcomeOf } from "@/lib/update-outcome";

type Report = (error: string) => void;

/** What one place's Update did: whether the command landed at all, and
 *  what the plan wrote and what it held back. Both commands report it, so
 *  a landed apply always carries the record and a failed one never
 *  needs to invent an empty stand-in for it. */
export type ApplyOutcome =
  | { ok: false }
  | { ok: true; update: PackageUpdate_Serialize };

/** Bring one place current. Held packages move by moving the hold;
 *  following ones come current through the single-package apply. Either
 *  way the write reaches this package alone — a sibling follower in the
 *  same scope stays at its installed version, unless the lock cannot place
 *  it, in which case it resolves fresh as a whole-scope apply would give
 *  it anyway. Failures go through `report`. */
export const applyRow = async (
  row: UpdateRow,
  report: Report,
): Promise<ApplyOutcome> => {
  const response =
    row.pinned && row.latest
      ? await commands.packageSetRev(
          row.scope,
          row.kind,
          row.name,
          row.latest.commit,
        )
      : await commands.packageUpdate(row.scope, row.kind, row.name);
  if (response.status === "error") {
    report(response.error);
    return { ok: false };
  }
  return { ok: true, update: response.data };
};

/** Bring every place in `rows` current, one package-scoped apply per
 *  place, writing each answer into the caller's `outcome` as it comes.
 *
 *  Nothing is returned, on purpose: a returned record is one an assignment
 *  can lose, and a place that rejects at the transport layer would take
 *  every earlier place's committed result with it. The caller holds the
 *  record from before the first apply until after the last, and a throw
 *  leaves it holding everything said up to that point.
 *
 *  Deciding here what the answers mean is how this path fell behind the
 *  per-row one twice: it reads `outcomeOf` instead. */
export const applyRows = async (
  rows: UpdateRow[],
  report: Report,
  outcome: BulkOutcome,
): Promise<void> => {
  for (const row of rows) {
    const one = await applyRow(row, report);
    if (!one.ok) {
      outcome.ok = false;
      continue;
    }
    // Read, never re-derived: the same answer the per-row report shows, so
    // a disposition added later reaches this count too.
    const what = outcomeOf(one.update);
    if (what.moved) outcome.moved.push(row);
    if (what.held.length > 0) outcome.held += 1;
    if (what.removed.length > 0) outcome.removed += 1;
  }
};
