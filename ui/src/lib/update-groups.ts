import type { Scope, UpdateRow } from "@/bindings";
import { USER_LEVEL_PLACE } from "@/lib/copy";
import { scopeKey } from "@/lib/scope";

/** One package with every place it is out of date in. The same skill
 *  installed in three projects is one decision with three places, not
 *  three identical rows. */
export interface UpdateGroup {
  kind: UpdateRow["kind"];
  name: string;
  places: UpdateRow[];
}

export const groupKey = (row: { kind: string; name: string }): string =>
  `${row.kind}:${row.name}`;

/** Group rows by package, keeping first-seen order for the groups and the
 *  rows' own order inside each. */
export function groupUpdates(rows: UpdateRow[]): UpdateGroup[] {
  const groups = new Map<string, UpdateGroup>();
  for (const row of rows) {
    const key = groupKey(row);
    const group = groups.get(key);
    if (group) group.places.push(row);
    else groups.set(key, { kind: row.kind, name: row.name, places: [row] });
  }
  return [...groups.values()];
}

/** How many distinct packages have news — the sidebar's number. */
export const packageCount = (rows: UpdateRow[]): number =>
  new Set(rows.map(groupKey)).size;

/** The places "Update all" can act on: a newer version exists and no local
 *  edit is holding it. Edited places need the fork decision first. */
export const updatablePlaces = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => row.updateAvailable && !row.blockedByLocalEdit);

/** Where a package lives, as a person names it: the project folder, or
 *  "User level" for the install that applies everywhere. */
export function placeName(scope: Scope): string {
  if (scope.scope === "global") return USER_LEVEL_PLACE;
  return scope.root.split("/").pop() ?? scope.root;
}

export const placeKey = (row: UpdateRow): string =>
  `${groupKey(row)}:${scopeKey(row.scope)}`;
