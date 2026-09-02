// How rows come current: a held place moves its hold, a following place
// runs the single-package apply — both scoped to the package, so a place's
// Update does not move that scope's other followers (bar one the lock
// cannot place, which resolves fresh either way). A run over several rows
// asks each place for all of its at once, so the scope reconciles and
// applies once however many rows it has. Kept beside the store the way its
// read landing and edit flows are, so the store body stays the state
// lifecycle.
import { toast } from "sonner";
import {
  commands,
  type DriftRow_Serialize,
  type PackageUpdate_Serialize,
  type Scope,
  type UpdateRow,
  type UpdateTarget,
} from "@/bindings";
import {
  ALREADY_CURRENT_TOAST,
  heldBackToastLabel,
  removedNotReplacedToastLabel,
  unansweredPackageError,
  updatedCountToastLabel,
} from "@/lib/copy-updates";
import { harnessName } from "@/lib/labels";
import { scopeKey } from "@/lib/scope";
import { sayUndone } from "@/lib/undone";

type Report = (error: string) => void;

/** What one place's Update did: whether the command landed at all, and
 *  what the plan wrote and what it held back. Both commands report it, so
 *  a landed apply always carries the record and a failed one never
 *  needs to invent an empty stand-in for it. */
export type ApplyOutcome =
  | { ok: false }
  | { ok: true; update: PackageUpdate_Serialize };

/** The three lists an apply answers with about one package: what it took
 *  to the trash, what it refused to write over, and where it wrote. A run
 *  over several places is their concatenation, so the single-package
 *  surface and the bulk one read one shape and say one thing. */
export type Dispositions = Pick<
  PackageUpdate_Serialize,
  "removed" | "heldBack" | "moved"
>;

/** What a run over several places gathered: the three lists, and the rows
 *  that asked for what landed in them. A rendering carries a kind and a
 *  name but no repository, and two projects installing a `gh` skill from
 *  unrelated catalogs are two packages — so how many packages a run wrote
 *  or lost is counted off these rows with `update-groups.ts`
 *  [`packageCount`], which is the one identity rule, never off the
 *  renderings. */
export interface RunRecord extends Dispositions {
  /** The rows whose package the plan wrote somewhere. */
  wrote: UpdateRow[];
  /** The rows whose copy went to the trash with nothing written back. */
  lost: UpdateRow[];
}

/** A fresh record for a run to gather its places' answers into. The caller
 *  holds it from before the first apply until after the last, so a place
 *  that rejects at the transport layer cannot take what earlier places
 *  already committed with it. */
export const noRun = (): RunRecord => ({
  removed: [],
  heldBack: [],
  moved: [],
  wrote: [],
  lost: [],
});

/** The tools named by a set of drift rows, each once, in the order they
 *  came back. */
const toolsOf = (rows: DriftRow_Serialize[]): string[] => [
  ...new Set(rows.map((row) => harnessName(row.harness))),
];

/** What a run over several places claims, or null where it claims nothing.
 *
 *  A run that wrote no package is one of two runs, and they are not alike.
 *  Every apply can have failed, in which case its errors are already on
 *  screen and a line beside them would be the only untrue thing there. Or
 *  every apply committed and the plan had nothing to write: core's
 *  `moving` reports only the renderings it found missing or stale, so a
 *  package another window, another lane or the CLI brought current between
 *  the check and the click answers with three empty lists. That run did
 *  what it was asked, and the single-package surface says "Updated <name>"
 *  over the very same answer, so this one speaks too. */
export const bulkLine = (moved: number, failed: boolean): string | null => {
  if (moved > 0) return updatedCountToastLabel(moved);
  return failed ? null : ALREADY_CURRENT_TOAST;
};

/** Say what an apply did, off its three lists and nothing else. A copy
 *  taken to the trash outranks the rest — it is the one outcome that took
 *  something away — then a copy the plan left exactly as it is, then
 *  `done`, the surface's own word for having written the package.
 *
 *  `done` is null only where the surface has nothing to claim because it
 *  could not act: a run whose every apply failed, whose errors are already
 *  on screen. A run that committed always passes a line, even one that
 *  wrote nothing — an apply answers with three empty lists for a package
 *  something else brought current, and silence over that reads as a click
 *  that missed.
 *
 *  `lost` is how many packages `what.removed` is about, which the lists
 *  cannot answer: a rendering carries no repository, so the surface that
 *  knows the packages counts them. One for a single-package apply; a run's
 *  own count of [`RunRecord.lost`] for a bulk one. */
export const sayApply = (
  done: string | null,
  what: Dispositions,
  lost: number,
): void => {
  const removed = toolsOf(what.removed);
  if (removed.length > 0) {
    toast.error(removedNotReplacedToastLabel(lost, removed));
    return;
  }
  const held = toolsOf(what.heldBack);
  if (held.length > 0) {
    toast.info(heldBackToastLabel(held));
    return;
  }
  if (done !== null) toast.success(done);
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
 *  of that place's rows, gathering each answer into the caller's `into` as
 *  it comes.
 *
 *  Nothing is returned, on purpose: a returned record is one an assignment
 *  can lose, and a place that rejects at the transport layer would take
 *  every earlier place's committed result with it. The caller holds the
 *  record from before the first apply until after the last, and a throw
 *  leaves it holding everything said up to that point.
 *
 *  The answers are gathered, never re-read here: what a run did is the
 *  same three lists one apply answers with, so [`sayApply`] says it for
 *  both surfaces. The row that asked is kept beside them, because it
 *  carries the repository the renderings do not and a count of packages
 *  needs it. */
export const applyRows = async (
  rows: UpdateRow[],
  report: Report,
  into: RunRecord,
): Promise<void> => {
  for (const place of byPlace(rows)) {
    const response = await commands.packageUpdateMany(
      place.scope,
      place.rows.map(targetOf),
    );
    // One plan, one apply: a place that fails takes all of its own rows
    // with it and none of any other place's. Its error is already on
    // screen through `report`.
    if (response.status === "error") {
      report(response.error);
      continue;
    }
    sayUndone(response.data.view.undone);
    const answered = new Map(
      response.data.packages.map((one) => [targetKey(one), one]),
    );
    for (const row of place.rows) {
      const one = answered.get(targetKey(row));
      // The apply committed; what it did to this package is what did not
      // come back. Said out loud, because a silent drop makes the run's
      // own account read short.
      if (!one) {
        report(unansweredPackageError(row.name));
        continue;
      }
      into.removed.push(...one.removed);
      into.heldBack.push(...one.heldBack);
      into.moved.push(...one.moved);
      if (one.moved.length > 0) into.wrote.push(row);
      if (one.removed.length > 0) into.lost.push(row);
    }
  }
};
