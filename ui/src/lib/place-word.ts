import type { Scope } from "@/bindings";

/** What a counted set of places is called. Projects among themselves are
 *  projects; the personal setup is not a project, so a set holding it is a
 *  set of places — the word the rest of the app already uses for the mixed
 *  case, from `copy-model.ts`'s "your personal setup, and every project you
 *  add" down.
 *
 *  Alone in its own module on purpose, the way `listed.ts` is. Two surfaces
 *  count places out loud — the package page's customization mark
 *  (`place-marks.ts`) and a marketplace's "Installed in" control
 *  (`copy-marketplaces.ts`) — and a second copy of this rule is how one of
 *  them ends up calling the personal setup a project.
 *
 *  `count` is what the noun agrees with, which is not always the length of
 *  the set being named: a mark reading "1 of 3 places" names three places
 *  and counts by three. It defaults to the set's own size. */
export const placeWord = (scopes: Scope[], count = scopes.length): string => {
  const projects = scopes.every((scope) => scope.scope === "project");
  if (projects) return count === 1 ? "project" : "projects";
  return count === 1 ? "place" : "places";
};
