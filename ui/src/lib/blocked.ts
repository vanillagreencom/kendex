// Declared items whose place already holds files kendex did not write.
// The plan cannot move one of these on its own: keeping the files and
// installing over them are opposite directions, and only a person picks.
import type { AuditView, DriftRow, Scope } from "@/bindings";
import { type MergedDriftRow, mergeDriftRows } from "@/lib/drift-merge";
import { Exits } from "@/lib/exits";

export interface BlockedPlace {
  /** Stable across audits, so a re-render keeps the card it was drawn as. */
  key: string;
  scope: Scope;
  /** One entry per declared item, whatever the number of tools it targets. */
  rows: MergedDriftRow[];
  exits: Exits;
  /** Whether this place has other work waiting. Either exit runs the
   *  place's whole plan, so both confirmations say so where it is true. */
  alsoApplies: boolean;
}

const itemKey = (row: DriftRow) => `${row.kind}:${row.name}`;

/** The blocked items at one place, or none. Every conflict an item with
 *  files in the way has belongs on its row: both exits act on the whole
 *  item, so a place nothing can settle takes the offers off the ones beside
 *  it. A conflict of another kind on its own is not a decision about files
 *  and is left out. */
export function blockedIn(view: AuditView): MergedDriftRow[] {
  const exits = new Exits(view.exits);
  const withFiles = new Set(
    view.drift.filter((row) => exits.files(row)).map(itemKey),
  );
  return mergeDriftRows(
    view.drift.filter(
      (row) => exits.blocking(row) && withFiles.has(itemKey(row)),
    ),
  );
}

/** Every place holding a blocked item, in the order the audit reports them.
 *
 *  A place the audit could not read is skipped. Its rows are a picture
 *  nothing has confirmed, and both exits here write to the filesystem from
 *  exactly those rows. That place already states its own failure as a
 *  problem of its own, so nothing goes unsaid by leaving it out. */
export function blockedPlaces(views: AuditView[]): BlockedPlace[] {
  const places: BlockedPlace[] = [];
  for (const view of views) {
    if (view.error) continue;
    const rows = blockedIn(view);
    if (rows.length === 0) continue;
    places.push({
      key: view.scope.scope === "global" ? "global" : view.scope.root,
      scope: view.scope,
      rows,
      exits: new Exits(view.exits),
      alsoApplies: view.plan.length > 0,
    });
  }
  return places;
}

/** How many blocked items there are across every place, which is what the
 *  status footer counts alongside the problems it already reports. */
export const blockedCount = (places: BlockedPlace[]): number =>
  places.reduce((total, place) => total + place.rows.length, 0);
