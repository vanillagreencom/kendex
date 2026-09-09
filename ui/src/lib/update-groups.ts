import type { Scope, UpdateRow } from "@/bindings";
import {
  EDITED_CANT_UPDATE_NOTE,
  HELD_BY_OWNER_NOTE,
  heldByParentNote,
  USER_LEVEL_PLACE,
} from "@/lib/copy-updates";
import { sameScope, scopeKey } from "@/lib/scope";

/** One package with every place it is out of date in. The same skill
 *  installed in three projects is one decision with three places, not
 *  three identical rows. */
export interface UpdateGroup {
  kind: UpdateRow["kind"];
  name: string;
  repoIdentity: string;
  places: UpdateRow[];
}

/** A package's identity: kind, name, and the repository it comes from —
 *  two projects installing a `gh` skill from unrelated catalogs are two
 *  packages, not one in two places. The backend's canonical identity
 *  keeps two spellings of one repository together. */
export const groupKey = (row: {
  kind: string;
  name: string;
  repoIdentity: string;
}): string => `${row.kind}:${row.name}:${row.repoIdentity}`;

/** Group rows by package, keeping first-seen order for the groups and the
 *  rows' own order inside each. */
export function groupUpdates(rows: UpdateRow[]): UpdateGroup[] {
  const groups = new Map<string, UpdateGroup>();
  for (const row of rows) {
    const key = groupKey(row);
    const group = groups.get(key);
    if (group) group.places.push(row);
    else
      groups.set(key, {
        kind: row.kind,
        name: row.name,
        repoIdentity: row.repoIdentity,
        places: [row],
      });
  }
  return [...groups.values()];
}

/** How many distinct packages have news — the sidebar's number. */
export const packageCount = (rows: UpdateRow[]): number =>
  new Set(rows.map(groupKey)).size;

/** Why this place's Update is withheld, or null when nothing withholds it.
 *  Every surface that offers Update reads this one function — the update
 *  review dialog, the row's own button, and the package page through
 *  `updates-read-state.ts` [`packageUpdateNote`], which takes the kind's
 *  refusal off the row before the update read's own state and delegates
 *  everything after that here. So an offer and the refusal beside it
 *  still come from one reading of the row; where that reading ranks
 *  against the read is `packageUpdateNote`'s to state, and it states it
 *  in full.
 *
 *  One nullable note, and not a verdict beside it: a reason that cannot be
 *  said is a reason that cannot be written here, so a gate reading this can
 *  never hide a button it has no words for. The kind's refusal is core's
 *  own, carried on the row; the UI never works out for itself which kinds
 *  are brought current one at a time.
 *
 *  Having nothing newer to move to is not a reason — that place is current,
 *  not refused, and each surface knows its own newness. [`canUpdatePlace`]
 *  is this reading plus the row's. */
export const updateWithheld = (row: UpdateRow): string | null => {
  // The kind's refusal first: it is why this row can never be updated
  // here, where the rest are why not right now.
  if (row.noPerPackageUpdate !== null) return row.noPerPackageUpdate;
  // An edited place is never updated over; its row offers the install
  // beside it instead.
  if (row.blockedByLocalEdit) return EDITED_CANT_UPDATE_NOTE;
  // A hold this declaration does not own: named where a requirement
  // propagated it, unnamed where a bundle did. It is released where it was
  // set, which is the package page and never this table.
  if (heldByOwner(row))
    return row.holdOwner?.kind === "parent" && row.holdOwner.name
      ? heldByParentNote(row.holdOwner.name)
      : HELD_BY_OWNER_NOTE;
  return null;
};

/** Whether this place can take its update right now: a newer version to
 *  move to, and nothing withholding it. */
export const canUpdatePlace = (row: UpdateRow): boolean =>
  row.updateAvailable && updateWithheld(row) === null;

/** The places "Update all" can act on: a newer version exists and nothing
 *  stands in the way. */
export const updatablePlaces = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter(canUpdatePlace);

/** A bundle member or dependency held at its owner's revision: the hold
 *  is the owner's to move, so nothing here can update or release it. */
const heldByOwner = (row: UpdateRow): boolean => row.pinned && row.derived;

/** One place and every row of this list that is in it. */
export interface PlaceRows {
  scope: Scope;
  rows: UpdateRow[];
}

/** The places holding something an update can actually take, each with all
 *  of that place's rows — not only the takeable ones, so a run offered for
 *  one place can still say what it leaves alone there. First-seen order,
 *  like [`groupUpdates`]. This is what lets "update a project's" be a
 *  choice beside "update all" without narrowing the page by location. */
export function placesWithUpdates(rows: UpdateRow[]): PlaceRows[] {
  const places = new Map<string, PlaceRows>();
  for (const row of rows) {
    const key = scopeKey(row.scope);
    const place = places.get(key);
    if (place) place.rows.push(row);
    else places.set(key, { scope: row.scope, rows: [row] });
  }
  return [...places.values()].filter(
    (place) => updatablePlaces(place.rows).length > 0,
  );
}

/** Places with news that a bulk update has to leave alone — edited ones,
 *  which no update may overwrite, held derived ones waiting on their
 *  owner, and kinds whose update lives elsewhere. The complement of
 *  [`updatablePlaces`] over the same news, so every place with something
 *  to say is counted once. */
export const skippedPlaces = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => row.updateAvailable && !canUpdatePlace(row));

/** Where a package lives, as a person names it: the project folder, or
 *  "User level" for the install that applies everywhere. Two projects
 *  with the same folder name among `among` get their parent folder too,
 *  so ~/work/app and ~/clients/app never read as one place twice. */
export function placeName(scope: Scope, among: Scope[] = []): string {
  if (scope.scope === "global") return USER_LEVEL_PLACE;
  const parts = pathParts(scope.root);
  const others = among.flatMap((other) =>
    other.scope === "project" && other.root !== scope.root
      ? [pathParts(other.root)]
      : [],
  );
  // The shortest trailing run of folders no other place in the group
  // ends with — one folder when nothing clashes, the whole root if even
  // that is shared.
  for (let take = 1; take <= parts.length; take += 1) {
    const suffix = parts.slice(-take).join("/");
    if (!others.some((other) => other.slice(-take).join("/") === suffix))
      return suffix;
  }
  return scope.root;
}

// Roots are serialized by the OS that wrote them, so a Windows project
// arrives with backslashes; either separator ends a folder name.
const pathParts = (root: string): string[] =>
  root.split(/[\\/]+/).filter((part) => part !== "");

export const placeKey = (row: UpdateRow): string =>
  `${groupKey(row)}:${scopeKey(row.scope)}`;

/** A row worth a line on the page: a newer version, a package gone from
 *  its source, or installs disagreeing on their version — each a standing
 *  fact someone can act on. */
const noteworthy = (row: UpdateRow): boolean =>
  row.updateAvailable || row.removedUpstream || row.mixed;

/** The sidebar badge's number: packages with news someone would want to
 *  hear, counted once however many places they are installed in. Ignored
 *  ones asked not to be counted; held ones still count — a hold is "not
 *  yet", not "never tell me". */
export const visibleUpdateCount = (rows: UpdateRow[]): number =>
  packageCount(visibleUpdates(rows));

/** The Updates page's main list: everything noteworthy that has not been
 *  muted. */
export const visibleUpdates = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => noteworthy(row) && !row.ignored);

/** The packages with a newer version to move to, muted ones aside.
 *
 *  Narrower than [`visibleUpdates`] on purpose, and this is the difference:
 *  a package its source no longer carries, and installs disagreeing on a
 *  version, are news the Updates page lists and tags — they are not
 *  updates, they carry no `latest` and no Update, and core builds them with
 *  `updateAvailable` false. So a surface whose words claim an update is
 *  available — Home's count, a place's card, the Library's mark — asks
 *  this, and a surface that lists the page's news asks `visibleUpdates`.
 *  Every one of the three asks it here rather than spelling the rule again,
 *  so they cannot come apart. */
export const availableUpdates = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => row.updateAvailable && !row.ignored);

/** How many packages have an update, machine-wide — Home's number. */
export const availableUpdateCount = (rows: UpdateRow[]): number =>
  packageCount(availableUpdates(rows));

/** The packages with an update in one place — a place card's number, and
 *  the rows its review acts on. */
export const availableUpdatesIn = (
  rows: UpdateRow[],
  scope: Scope,
): UpdateRow[] =>
  availableUpdates(rows).filter((row) => sameScope(row.scope, scope));

export const outOfDateIn = (rows: UpdateRow[], scope: Scope): number =>
  packageCount(availableUpdatesIn(rows, scope));

/** The collapsed "hidden updates" section: muted packages whose news is
 *  still real — with the way back out. */
export const hiddenUpdates = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => noteworthy(row) && row.ignored);
