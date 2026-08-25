// How rows come current: a held place moves its hold, a following place
// applies its scope, and a bulk run never applies one scope twice — kept
// beside the store the way its read landing and edit flows are, so the
// store body stays the state lifecycle.
import { commands, type UpdateRow } from "@/bindings";
import { scopeKey } from "@/lib/scope";

type Report = (error: string) => void;

/** Bring one place current. Held packages move by moving the hold;
 *  following ones come current by applying the scope — which is what
 *  following means, and brings any other pending changes in that scope
 *  along. Returns whether it landed; failures go through `report`. */
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
      : await commands.applyPlan(row.scope, false);
  if (response.status === "error") {
    report(response.error);
    return false;
  }
  return true;
};

/** Bring every place in `rows` current: every hold first — each move
 *  applies its whole scope, so that scope's followers are already current
 *  — then one apply per scope no hold touched. Never two applies for one
 *  scope. Returns whether every step landed. */
export const applyRows = async (
  rows: UpdateRow[],
  report: Report,
): Promise<boolean> => {
  let ok = true;
  const applied = new Set<string>();
  for (const row of rows.filter((row) => row.pinned)) {
    if (await applyRow(row, report)) applied.add(scopeKey(row.scope));
    else ok = false;
  }
  const scopes = new Map(
    rows
      .filter((row) => !row.pinned && !applied.has(scopeKey(row.scope)))
      .map((row) => [scopeKey(row.scope), row] as const),
  );
  for (const row of scopes.values()) {
    const response = await commands.applyPlan(row.scope, false);
    if (response.status === "error") {
      report(response.error);
      ok = false;
    }
  }
  return ok;
};
