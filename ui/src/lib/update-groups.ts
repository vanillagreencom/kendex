import type { Scope, UpdateRow } from "@/bindings";
import {
  EDITED_CANT_UPDATE_NOTE,
  HELD_BY_OWNER_NOTE,
  NO_UPDATE_STANDING_NOTE,
  UPDATE_NEEDS_CHECK_HERE,
  UPDATES_CHECKING,
  USER_LEVEL_PLACE,
} from "@/lib/copy-updates";
import { scopeKey } from "@/lib/scope";
import {
  settlingIn,
  unsettled,
  updatesReadState,
} from "@/lib/updates-read-state";

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
 *  Every surface that offers Update reads this one function — "Update
 *  all", the row's own button, the package page — so an offer and the
 *  refusal beside it can never come from two readings of the same row.
 *
 *  One nullable note, and not a verdict beside it: a reason that cannot be
 *  said is a reason that cannot be added here, so a gate reading this can
 *  never hide a button it has no words for. The kind's refusal is core's
 *  own, carried on the row; the UI never works out for itself which kinds
 *  are brought current one at a time.
 *
 *  Having nothing newer to move to is not a reason — that place is current,
 *  not refused, and each surface knows its own newness. [`canUpdatePlace`]
 *  is this reading plus the row's. */
export const updateWithheld = (row: UpdateRow): string | null => {
  // The kind first, for the reason [`pageUpdateWithheld`] states in full:
  // it is why this row never can be updated here, where the rest are why
  // not right now.
  if (row.noPerPackageUpdate !== null) return row.noPerPackageUpdate;
  // An edited place is never updated over; its row offers the install
  // beside it instead.
  if (row.blockedByLocalEdit) return EDITED_CANT_UPDATE_NOTE;
  if (heldByOwner(row)) return HELD_BY_OWNER_NOTE;
  return null;
};

/** Whether this place can take its update right now: a newer version to
 *  move to, and nothing withholding it. */
export const canUpdatePlace = (row: UpdateRow): boolean =>
  row.updateAvailable && updateWithheld(row) === null;

/** Everything `updates-read-state.ts` needs to say how the read went and
 *  whether a write is running in a given place. */
type UpdatesReadStanding = Parameters<typeof settlingIn>[0] &
  Parameters<typeof unsettled>[0] &
  Parameters<typeof updatesReadState>[0];

/** Unreachable by construction — `read` is `never` here, so nothing calls
 *  this and no test can reach it. Its point is the compile error a new
 *  `UpdatesReadState` variant raises: without it that state would fall
 *  through to the row and answer "nothing withheld" over an unread read. */
const unhandledReadState = (state: never): never => {
  throw new Error(`unhandled update read state: ${String(state)}`);
};

/** Why the package page has no Update for the place it is showing.
 *
 *  **The invariant**: every state in which this place may not be acted on
 *  — a read still pending, a read that failed, a place the read never
 *  covered, a write already running there, and the row's own reasons —
 *  answers with a note. That is what lets [`canUpdatePackage`] gate on
 *  `withheld === null` and keep no reading of its own: a state that cannot
 *  say why is a state that cannot hide the button. Nothing withheld
 *  answers null, and the cases in update-groups.test.ts are the proof.
 *
 *  **The order**, stated here once for both surfaces. The kind's refusal
 *  comes first: it is why this place can never be updated here rather than
 *  why not right now, and it is derived from the kind rather than from
 *  anything a read could refresh, so no check clears it and none should
 *  appear to. Then the read, because every remaining reason is a fact the
 *  read supplied and a read that has not landed cannot vouch for it. Then
 *  the row's own remaining reasons.
 *
 *  A read merely *in flight* does not bar a row that exists. That guard
 *  belongs to the Updates table, whose actions send `row.latest.commit`
 *  and so must not commit values a landing read is about to replace; this
 *  page's Update sends only scope, kind and name, and takes its versions
 *  from its own read. Refusing here would unmount the button on every
 *  window focus, which raises `overviewInFlight` for the whole overview
 *  read. It does bear on a place with no row, which is a different
 *  question — not whether a value is stale, but whether the read has
 *  finished saying which places it covers.
 *
 *  Of the reasons [`updateWithheld`] gives, the owner's hold is the one
 *  this page never renders: it wants a derived place, and core's version
 *  timeline refuses a package the manifest does not declare, so the page
 *  has no newer version to offer there in the first place. Proven in
 *  crates/core/tests/package_versions.rs, not assumed here. */
export const pageUpdateWithheld = (
  row: UpdateRow | null,
  standing: UpdatesReadStanding,
): string | null => {
  if (row?.noPerPackageUpdate != null) return row.noPerPackageUpdate;
  const read = updatesReadState(standing);
  switch (read) {
    case "pending":
      return UPDATES_CHECKING;
    case "failed":
      return UPDATE_NEEDS_CHECK_HERE;
    case "landed":
      break;
    default:
      return unhandledReadState(read);
  }
  // No row here. Whether that is a fact depends on whether the read is
  // finished: one about to replace every row may be about to produce this
  // one, and saying it has not spoken for the place claims a ruling it is
  // still making. Only a settled read may say "nothing here".
  if (row === null) {
    return unsettled(standing) ? UPDATES_CHECKING : NO_UPDATE_STANDING_NOTE;
  }
  // A Follow source flip is applying in this very place; a second write
  // would contend for the same writer lock.
  if (settlingIn(standing, row)) return UPDATE_NEEDS_CHECK_HERE;
  return updateWithheld(row);
};

/** The places "Update all" can act on: a newer version exists and nothing
 *  stands in the way. */
export const updatablePlaces = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter(canUpdatePlace);

/** A bundle member or dependency held at its owner's revision: the hold
 *  is the owner's to move, so nothing here can update or release it. */
export const heldByOwner = (row: UpdateRow): boolean =>
  row.pinned && row.derived;

/** Why the Follow source switch is not this row's to flip, if it is not:
 *  a derived package has no declaration of its own to set a hold on, and a
 *  hold that belongs to the source or to a parent is released there. */
export const switchLockedBy = (
  row: UpdateRow,
): { kind: "source"; name: string } | { kind: "parent" } | null => {
  if (row.holdOwner?.kind === "source")
    return { kind: "source", name: row.holdOwner.name };
  if (row.derived || row.holdOwner?.kind === "parent")
    return { kind: "parent" };
  return null;
};

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

/** The collapsed "hidden updates" section: muted packages whose news is
 *  still real — with the way back out. */
export const hiddenUpdates = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => noteworthy(row) && row.ignored);
