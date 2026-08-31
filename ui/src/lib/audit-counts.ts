// One place the app reads what the audit found is unmanaged, so a project's
// card and the page behind it can never quote different numbers for the
// same thing.
//
// The engine emits one drift row per harness an item targets, so a skill
// present for five tools is five rows and one thing. A person counts the
// thing. Counting happens inside one scope: the same name in two projects
// is genuinely two items, and folding those together would undercount.
import type { AuditView, DriftRow, Scope } from "@/bindings";
import { type MergedDriftRow, mergeDriftRows } from "@/lib/drift-merge";
import { Exits } from "@/lib/exits";

/** Everything at this place kendex did not put there, one entry per item
 *  however many tools it is installed for. Adopting is an offer the user
 *  takes up, so this is never work waiting on them.
 *
 *  Null where the audit could not read this place. What is there is
 *  genuinely unknown, and an empty list is a claim: it would read as
 *  "nothing unmanaged here", and every row the app would have offered to
 *  adopt writes to the filesystem. Null so no caller can spend it as a
 *  number without deciding what to say.
 *
 *  A reading fails two ways and both land here, because both leave the same
 *  rows standing from the last audit that worked: one place refuses to be
 *  read and its own view carries the error, or the whole check fails and
 *  the store keeps every view it had. Taking both in one argument each is
 *  what stops a caller reading one channel and missing the other. An
 *  undefined view is neither: the audit has not reached this place yet,
 *  which is an empty answer rather than an unknown one. */
export function unmanagedIn(
  view: AuditView | undefined,
  failure: string | null,
): MergedDriftRow[] | null {
  if (failure !== null || view?.error) return null;
  if (!view) return [];
  return mergeDriftRows(view.drift.filter((row) => row.state === "unmanaged"));
}

export const unmanagedCount = (
  view: AuditView | undefined,
  failure: string | null,
): number | null => unmanagedIn(view, failure)?.length ?? null;

/** A declared item at this place whose position already holds files kendex
 *  did not write, one entry per item however many tools it targets.
 *
 *  Every conflict such an item has is here: both exits act on the whole
 *  item, so a place nothing can settle takes the offers off the ones beside
 *  it. A conflict of another kind on its own is not a decision about files
 *  and is left out.
 *
 *  Null where the reading is unconfirmed, on the same two channels and for
 *  the same reason as `unmanagedIn` above: both exits offered here write to
 *  the filesystem from exactly these rows. */
export function blockedIn(
  view: AuditView | undefined,
  failure: string | null,
): MergedDriftRow[] | null {
  if (failure !== null || view?.error) return null;
  if (!view) return [];
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

const itemKey = (row: DriftRow) => `${row.kind}:${row.name}`;

/** One place's blocked items, with what the surface needs to draw them. */
export interface BlockedPlace {
  /** Stable across audits, so a re-render keeps the card it was drawn as. */
  key: string;
  scope: Scope;
  rows: MergedDriftRow[];
  exits: Exits;
  /** Whether this place has other work waiting. Either exit runs the
   *  place's whole plan, so both confirmations say so where it is true. */
  alsoApplies: boolean;
}

/** Every place holding a blocked item, or null where the reading is
 *  unconfirmed — a caller that spent null as an empty list would draw
 *  destructive buttons over rows nothing has looked at since. */
export function blockedPlaces(
  views: AuditView[],
  failure: string | null,
): BlockedPlace[] | null {
  if (failure !== null) return null;
  const places: BlockedPlace[] = [];
  for (const view of views) {
    const rows = blockedIn(view, failure);
    if (!rows || rows.length === 0) continue;
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
export const blockedCount = (places: BlockedPlace[] | null): number =>
  places?.reduce((total, place) => total + place.rows.length, 0) ?? 0;
