import type {
  ItemKind,
  PackageMeta_Serialize,
  Scope,
  UpdateRow,
} from "@/bindings";
import { sameScope, scopeKey } from "@/lib/scope";
import { placeName, updatablePlaces } from "@/lib/update-groups";

/** One place a package is installed in, as its card reads it. */
export interface PackagePlace {
  scope: Scope;
  /** What this place is called among the package's own places. */
  name: string;
  /** The place's own record, or null where nobody could read it. */
  installedAt: string | null;
  /** The place's update standing, or null while the update read has not
   *  spoken for it. */
  row: UpdateRow | null;
  /** An update is waiting here and this place can take it. Never merely
   *  `updateAvailable`: an Update offered over a hand edit or somebody
   *  else's hold is one the engine goes on to refuse. */
  updatable: boolean;
}

/** Every place this package sits in, joined to what the update read and
 *  each place's own record say about it. The place list is the scan's, so
 *  a place with no update row and no readable record still gets a card —
 *  it is installed there whatever the other two reads managed to say. */
export function packagePlaces(
  scopes: Scope[],
  kind: ItemKind,
  name: string,
  rows: UpdateRow[],
  metas: Record<string, PackageMeta_Serialize | null>,
): PackagePlace[] {
  return scopes.map((scope) => {
    const row =
      rows.find(
        (one) =>
          one.kind === kind && one.name === name && sameScope(one.scope, scope),
      ) ?? null;
    return {
      scope,
      name: placeName(scope, scopes),
      installedAt: metas[scopeKey(scope)]?.installedAt ?? null,
      row,
      updatable: row !== null && updatablePlaces([row]).length === 1,
    };
  });
}

/** The rows "Update all" acts on — one judge for the link and the buttons,
 *  so the link can never appear over a set of cards that carry none. */
export const updatableRows = (places: PackagePlace[]): UpdateRow[] =>
  places.flatMap((place) =>
    place.updatable && place.row !== null ? [place.row] : [],
  );
