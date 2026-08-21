import type { Scope, UpdateRow } from "@/bindings";
import { USER_LEVEL_PLACE } from "@/lib/copy-updates";
import { scopeKey } from "@/lib/scope";

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

/** The places "Update all" can act on: a newer version exists and no local
 *  edit is holding it. Edited places need the fork decision first. */
export const updatablePlaces = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter(
    (row) =>
      row.updateAvailable && !row.blockedByLocalEdit && !heldByOwner(row),
  );

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

/** Places with news that a bulk update has to leave alone — edited ones
 *  waiting on a decision, held derived ones waiting on their owner. */
export const skippedPlaces = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter(
    (row) =>
      row.updateAvailable && (row.blockedByLocalEdit || heldByOwner(row)),
  );

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
