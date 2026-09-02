import type {
  ItemKind,
  ObservedItem,
  PackageMeta_Serialize,
  ProvenanceRow,
  Scope,
  UpdateRow,
} from "@/bindings";
import { sameScope, scopeKey } from "@/lib/scope";
import { placeName, updatablePlaces } from "@/lib/update-groups";
import { rowUnsettled } from "@/lib/updates-read-state";

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

/** Whether kendex owns every one of this package's installations in one
 *  place.
 *
 *  A place holds one installation per harness and the provenance join is
 *  keyed the same way, so one row speaks for one harness and never for
 *  the place. Removing takes the declarations it finds and leaves the
 *  rest: with a managed copy beside an unmanaged or vendor one, a Remove
 *  would take half and the card would stay. So every installation has to
 *  be ours, and a place kendex knows nothing about is not ours either —
 *  vendor content is absent from the join by design, so a missing row is
 *  "not ours", never "nothing is there". */
const removableIn = (
  provenance: ProvenanceRow[],
  installs: ObservedItem[],
  kind: ItemKind,
  name: string,
  scope: Scope,
): boolean =>
  installs.length > 0 &&
  installs.every((install) => {
    const row = provenance.find(
      (one) =>
        one.kind === kind &&
        one.name === name &&
        one.harness === install.harness &&
        sameScope(one.scope, scope),
    );
    return row !== undefined && row.origin.origin !== "unmanaged";
  });

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

/** One place's identity for this package, as a string to key by. Scoped as
 *  well as named: another package in the same project, or this one in another
 *  project, is a different place. */
export const placeKey = (kind: ItemKind, name: string, scope: Scope): string =>
  `${kind}|${name}|${scopeKey(scope)}`;

/** These counts with one more write recorded against every place in `rows`.
 *
 *  Handed every place a run ATTEMPTED, not only those whose command answered
 *  ok. An error is not proof that nothing changed: `insert_manifest_save`
 *  leads a plan with the manifest write, so an apply that fails after it
 *  leaves the new hold on disk with nothing else moved, and a refusal ran a
 *  plan led the same way. A refresh that was not needed costs one re-read of
 *  a page already on screen; one that was needed and skipped is the stale
 *  Overview this whole record exists to remove — so this deliberately
 *  over-covers, and is not to be tightened back to what a plan moved. */
export const countingWrites = (
  writes: Record<string, number>,
  rows: { kind: ItemKind; name: string; scope: Scope }[],
): Record<string, number> => {
  const counted = { ...writes };
  for (const row of rows) {
    const key = placeKey(row.kind, row.name, row.scope);
    counted[key] = (counted[key] ?? 0) + 1;
  }
  return counted;
};

/** How many writes have landed in each place, as one string to watch — the
 *  same shape as [`installedCommits`] and read beside it.
 *
 *  A write that commits and then cannot be read back leaves the rows on the
 *  commit they had: nothing confirmed a new one, which is the truth about the
 *  rows and not about the files under them. So a landed write moves this
 *  whether or not the read behind it moved the commit, and a page about the
 *  place reads its package again either way. */
export const landedWrites = (
  writes: Record<string, number>,
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): string =>
  scopes.map((scope) => writes[placeKey(kind, name, scope)] ?? 0).join("|");

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
  installed: ObservedItem[],
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
      removable: removableIn(
        provenance,
        installed.filter(
          (one) =>
            one.kind === kind &&
            one.name === name &&
            sameScope(one.scope, scope),
        ),
        kind,
        name,
        scope,
      ),
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

/** Who ships this package at one place, when a tool ships it itself.
 *
 *  A place holds one installation per harness and the safety reading merges
 *  every one of them, so the vendor question is asked of the same set. One
 *  vendor copy beside a copy the reader owns is a package with a real score,
 *  and naming a vendor there would hide it. Null the moment any copy there
 *  is the reader's own, or the vendors disagree. */
export function vendorAt(
  installs: ObservedItem[],
  scope: Scope,
): string | null {
  const here = installs.filter((install) => sameScope(install.scope, scope));
  const vendor = here[0]?.vendor ?? null;
  if (!vendor) return null;
  return here.every((install) => install.vendor === vendor) ? vendor : null;
}
