import type {
  ItemKind,
  PackageMeta_Serialize,
  ProvenanceRow,
  Scope,
  UpdateRow,
} from "@/bindings";
import { sameScope, scopeKey } from "@/lib/scope";
import { placeName, updatablePlaces } from "@/lib/update-groups";
import { rowUnsettled } from "@/lib/updates-read-state";
import { originFor } from "@/stores/provenance";

/** How the update read stands, as `rowUnsettled` asks it. The store keeps
 *  last-known rows through a failed or running read, so the rows alone
 *  never say whether they may be acted on. */
export type UpdatesStanding = Parameters<typeof rowUnsettled>[0];

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
  /** An update is waiting here and this place can take it right now.
   *  Never merely `updateAvailable`: an Update offered over a hand edit,
   *  somebody else's hold, or a row the store is holding is one the
   *  engine goes on to refuse. */
  updatable: boolean;
  /** kendex can take this copy away. `removeItem` removes what the
   *  manifest declares and what the lock owns, and deliberately cannot
   *  delete a file it only observed — so a Remove on one of those would
   *  leave the card exactly where it was. */
  removable: boolean;
}

/** Whether kendex owns this package's installation in one place. A copy
 *  the scan only observed carries an `unmanaged` origin, and content the
 *  tool ships itself carries no provenance row at all — the join drops
 *  vendor content rather than calling it unmanaged, so an absent row is
 *  "not ours" the same as an unmanaged one. */
const removableIn = (
  provenance: ProvenanceRow[],
  kind: ItemKind,
  name: string,
  scope: Scope,
): boolean => {
  const origin = originFor(provenance, kind, name, [scope]);
  return origin !== null && origin.origin !== "unmanaged";
};

/** This package's row in one place, or null where the update read never
 *  spoke for it. */
const rowFor = (
  rows: UpdateRow[],
  kind: ItemKind,
  name: string,
  scope: Scope,
): UpdateRow | null =>
  rows.find(
    (one) =>
      one.kind === kind && one.name === name && sameScope(one.scope, scope),
  ) ?? null;

/** The commit each place has installed, as one string to watch. Core
 *  stamps a new install date whenever the source hash moves, so a landed
 *  update changes this while an unrelated store touch leaves it alone —
 *  which makes it the one signal that a place's own record is worth
 *  reading again. */
export const installedCommits = (
  rows: UpdateRow[],
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): string =>
  scopes
    .map((scope) => rowFor(rows, kind, name, scope)?.current?.commit ?? "")
    .join("|");

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
  standing: UpdatesStanding,
  provenance: ProvenanceRow[],
): PackagePlace[] {
  return scopes.map((scope) => {
    const row = rowFor(rows, kind, name, scope);
    return {
      scope,
      name: placeName(scope, scopes),
      installedAt: metas[scopeKey(scope)]?.installedAt ?? null,
      row,
      // A row the store is holding — a read that failed, a check or a
      // load running, a follow switch settling here — names a `latest`
      // nobody confirmed. `updateOne` refuses those and says so, so the
      // card offers nothing rather than a button that only raises an
      // error.
      updatable:
        row !== null &&
        !rowUnsettled(standing, row) &&
        updatablePlaces([row]).length === 1,
      removable: removableIn(provenance, kind, name, scope),
    };
  });
}

/** The places "Remove all" would reach — one judge for that link and the
 *  cards' own buttons, so the link can never appear over a set of cards
 *  that carry none. */
export const removablePlaces = (places: PackagePlace[]): PackagePlace[] =>
  places.filter((place) => place.removable);

/** The rows "Update all" acts on — one judge for the link and the buttons,
 *  so the link can never appear over a set of cards that carry none. */
export const updatableRows = (places: PackagePlace[]): UpdateRow[] =>
  places.flatMap((place) =>
    place.updatable && place.row !== null ? [place.row] : [],
  );
