import type { ItemKind, ObservedItem, Scope, UpdateRow } from "@/bindings";
import {
  editedRowIn,
  type PlaceStanding,
  type PlacesSource,
  placeStandings,
  standingIn,
} from "@/lib/customized-places";
import { groupScopes, type ItemGroup, installationIn } from "@/lib/derive";
import type { PackageRef, PackageView } from "@/stores/nav";

// Where a mark leads. A mark that says a place is yours is only worth
// clicking if it opens the surface holding what it marks, so the fact that
// made the mark decides the destination — and every surface drawing one
// asks here rather than deciding for itself.

/** Where a mark leads: the first place carrying a change, and what the
 *  package page opens showing — the surface that holds that change, not
 *  whichever tab the page defaults to. Null when nothing is changed. */
export function markTarget(
  standings: PlaceStanding[],
): { scope: Scope; view?: PackageView } | null {
  const found = standings.find((one) => one.change != null);
  if (!found) return null;
  if (found.change === "settings")
    return { scope: found.scope, view: { mode: "customize" } };
  return { scope: found.scope };
}

/** The customized mark's destination as the two arguments the nav takes:
 *  the place the mark names — never the row's own first install — and the
 *  surface holding what was changed there. Null when nothing is changed. */
export function markNav(
  group: { kind: ItemKind; name: string },
  standings: PlaceStanding[],
): [PackageRef, PackageView | undefined] | null {
  const target = markTarget(standings);
  if (!target) return null;
  return [
    { kind: group.kind, name: group.name, scope: target.scope },
    target.view,
  ];
}

/** The Customize index's Open. Every row it lists is an overlay written on
 *  the Customize tab, so it opens that tab rather than the overview the
 *  page would otherwise default to. */
export const customizeNav = (ref: PackageRef): [PackageRef, PackageView] => [
  ref,
  { mode: "customize" },
];

/** Everything a package page derives about one place before it renders:
 *  the installation it is about, the place its header speaks for, and the
 *  row behind its edited-files notice. All three are about the place the
 *  page was opened at — which a customized mark can name any of — so they
 *  are derived together and the page cannot say two things about one
 *  place. The Customize tab's chips move the editor, not the page: a title
 *  following a chip while the actions under it stay put is the same split
 *  this page exists to close. `primary` is null when nothing is installed
 *  at that place, which is the page's cue to leave the way the reader
 *  came. */
export function packageMarks(
  source: PlacesSource,
  group: ItemGroup,
  opened: Scope,
): {
  primary: ObservedItem | null;
  selected: PlaceStanding | null;
  editedRow: UpdateRow | null;
} {
  const { kind, name } = group;
  const standings = placeStandings(source, kind, name, groupScopes(group));
  return {
    primary: installationIn(group, opened),
    selected: standingIn(standings, opened),
    editedRow: editedRowIn(source, kind, name, opened),
  };
}
