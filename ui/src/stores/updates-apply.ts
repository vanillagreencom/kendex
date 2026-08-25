// How rows come current: a held place moves its hold, a following place
// runs the single-package apply — both scoped to the package, so no place's
// Update moves that scope's other followers. Kept beside the store the way
// its read landing and edit flows are, so the store body stays the state
// lifecycle.
import { commands, type UpdateRow } from "@/bindings";

type Report = (error: string) => void;

/** Bring one place current. Held packages move by moving the hold;
 *  following ones come current through the single-package apply. Either
 *  way the write reaches this package alone — a sibling follower in the
 *  same scope stays at its installed version. Returns whether it landed;
 *  failures go through `report`. */
export const applyRow = async (
  row: UpdateRow,
  report: Report,
): Promise<boolean> => {
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
    return false;
  }
  return true;
};

/** Bring every place in `rows` current, one package-scoped apply per
 *  place. Returns whether every step landed. */
export const applyRows = async (
  rows: UpdateRow[],
  report: Report,
): Promise<boolean> => {
  let ok = true;
  for (const row of rows) {
    if (!(await applyRow(row, report))) ok = false;
  }
  return ok;
};
