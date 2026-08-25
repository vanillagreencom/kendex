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

type Report = (error: string) => void;

/** What one place's Update did: whether the command landed at all, and —
 *  for a following package — what the plan wrote and what it held back.
 *  A hold move reports neither: `packageSetRev` answers with the view
 *  alone. */
export type ApplyOutcome = {
  ok: boolean;
  update: PackageUpdate_Serialize | null;
};

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
  if (row.pinned && row.latest) {
    const response = await commands.packageSetRev(
      row.scope,
      row.kind,
      row.name,
      row.latest.commit,
    );
    if (response.status === "error") {
      report(response.error);
      return { ok: false, update: null };
    }
    return { ok: true, update: null };
  }
  const response = await commands.packageUpdate(row.scope, row.kind, row.name);
  if (response.status === "error") {
    report(response.error);
    return { ok: false, update: null };
  }
  return { ok: true, update: response.data };
};

/** Bring every place in `rows` current, one package-scoped apply per
 *  place. Returns whether every step landed. */
export const applyRows = async (
  rows: UpdateRow[],
  report: Report,
): Promise<boolean> => {
  let ok = true;
  for (const row of rows) {
    if (!(await applyRow(row, report)).ok) ok = false;
  }
  return ok;
};
