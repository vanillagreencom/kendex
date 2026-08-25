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

/** What a run over several places did: the places it wrote, and how many
 *  a conflict held back. A place held in one tool while another came
 *  current counts in both — it moved, and it still needs a decision. */
export type BulkOutcome = {
  ok: boolean;
  moved: UpdateRow[];
  held: number;
};

/** Bring every place in `rows` current, one package-scoped apply per
 *  place, keeping what each one reported. Reducing this to a boolean is
 *  how a run counts a package it never moved: the plan holds a rendering
 *  back rather than writing over it, and only the command it ran can say
 *  so. */
export const applyRows = async (
  rows: UpdateRow[],
  report: Report,
): Promise<BulkOutcome> => {
  const outcome: BulkOutcome = { ok: true, moved: [], held: 0 };
  for (const row of rows) {
    const one = await applyRow(row, report);
    if (!one.ok) {
      outcome.ok = false;
      continue;
    }
    // A hold move answers with the view alone, so it counts as moved on
    // the strength of the command succeeding — the same reading this path
    // has always had.
    if (!one.update || one.update.heldBack.length === 0) {
      outcome.moved.push(row);
      continue;
    }
    outcome.held += 1;
    if (one.update.moved.length > 0) outcome.moved.push(row);
  }
  return outcome;
};
