// How rows come current: a held place moves its hold, a following place
// runs the single-package apply — both scoped to the package, so a place's
// Update does not move that scope's other followers (bar one the lock
// cannot place, which resolves fresh either way). A run over several rows
// asks each place for all of its at once, so the scope reconciles and
// applies once however many rows it has. Kept beside the store the way its
// read landing and edit flows are, so the store body stays the state
// lifecycle.
import {
  commands,
  type PackageUpdate_Serialize,
  type Scope,
  type UpdateRow,
  type UpdateTarget,
} from "@/bindings";
import { unansweredPackageError } from "@/lib/copy-updates";
import { scopeKey } from "@/lib/scope";
import { sayUndone } from "@/lib/undone";
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
  sayUndone(response.data.view.undone);
  return { ok: true, update: response.data };
};

/** The rows of one place, in the order they came, grouped by the scope
 *  they share. Which rows travel together is what decides how many whole
 *  scope reconciles a run costs: one place is one apply, whether it has a
 *  row or five. */
const byPlace = (rows: UpdateRow[]): { scope: Scope; rows: UpdateRow[] }[] => {
  const places = new Map<string, { scope: Scope; rows: UpdateRow[] }>();
  for (const row of rows) {
    const place = places.get(scopeKey(row.scope));
    if (place) place.rows.push(row);
    else places.set(scopeKey(row.scope), { scope: row.scope, rows: [row] });
  }
  return [...places.values()];
};

/** A package's identity within one place — what matches a batch's answers
 *  back to the rows that asked for them. */
const targetKey = (target: { kind: string; name: string }): string =>
  `${target.kind}:${target.name}`;

/** What one row asks the batched apply for. A held place moves its hold to
 *  the version it is behind; a following place carries none and keeps its
 *  declaration exactly as it is. The same choice [`applyRow`] makes between
 *  the two single-package commands. */
const targetOf = (row: UpdateRow): UpdateTarget => ({
  kind: row.kind,
  name: row.name,
  hold: row.pinned && row.latest ? row.latest.commit : null,
});

/** Bring every place in `rows` current, one apply per place covering all
 *  of that place's rows, writing each answer into the caller's `outcome`
 *  as it comes.
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
  for (const place of byPlace(rows)) {
    const response = await commands.packageUpdateMany(
      place.scope,
      place.rows.map(targetOf),
    );
    // One plan, one apply: a place that fails takes all of its own rows
    // with it and none of any other place's.
    if (response.status === "error") {
      report(response.error);
      outcome.ok = false;
      continue;
    }
    sayUndone(response.data.view.undone);
    const answered = new Map(
      response.data.packages.map((one) => [targetKey(one), one]),
    );
    for (const row of place.rows) {
      const one = answered.get(targetKey(row));
      // The apply committed; what it did to this package is what did not
      // come back. Counted as neither moved nor held, and said out loud,
      // because a silent drop makes the run's own count read low.
      if (!one) {
        report(unansweredPackageError(row.name));
        outcome.ok = false;
        continue;
      }
      // Read, never re-derived: the same answer the per-row report shows,
      // so a disposition added later reaches this count too.
      const what = outcomeOf(one);
      if (what.moved) outcome.moved.push(row);
      if (what.held.length > 0) outcome.held += 1;
      if (what.removed.length > 0) outcome.removed += 1;
    }
  }
};
