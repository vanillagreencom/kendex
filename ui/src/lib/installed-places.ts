import type { Catalog, ProvenanceRow, Scope } from "@/bindings";
import { scopeKey } from "@/lib/scope";

/** One offered package's identity in the places index.
 *
 *  Joined with `::`, the way `stores/preinstall-safety.ts::safetyKey`
 *  already keys the same pair for the same rows — `packages-table.tsx`
 *  calls both on one row, and one keying convention beats two. A name
 *  cannot carry `::`: every offered name passes `names::item_problem`
 *  before the catalog offers it. */
export const placesKey = (kind: string, name: string): string =>
  `${kind}::${name}`;

/** Personal leads, then projects by their root. Total, so a sort cannot be
 *  handed -1 for both (a,b) and (b,a). The same order the marketplace's own
 *  list of places draws, so a package's places and its marketplace's places
 *  never read in two orders on one page. */
const personalFirst = (a: Scope, b: Scope): number =>
  Number(b.scope === "global") - Number(a.scope === "global") ||
  scopeKey(a).localeCompare(scopeKey(b));

/** Where each of a marketplace's packages is installed, keyed by the
 *  package each installation belongs to — the places themselves, for the
 *  caller to name and open.
 *
 *  The join is on that package reference, not on what the scan observed,
 *  because an observed name is not a package name: a hook is registered
 *  under its event, matcher and command stem, so a catalog's hook is never
 *  found under the spelling the row carries, and an unrelated package whose
 *  stem happens to equal a catalog name would be credited to it.
 *
 *  Built once for a whole table rather than per row: the provenance join is
 *  a flat list of every installation on the machine, and filtering it per
 *  row costs the table one full scan per package.
 *
 *  An alias is not an identity. The same one can be declared in the
 *  personal manifest and in a project's, pointing at different
 *  repositories, so matching the alias alone credits this marketplace with
 *  installations that came from somebody else's — and a package installed
 *  under the same name from another source is a collision, which the
 *  Status column already says. `repo` is what tells the two apart, so the
 *  join asks for both.
 *
 *  Scope is deliberately spanned, not matched: a package installed into a
 *  project from a personal subscription is exactly what this exists to
 *  name, and joining on scope would drop it.
 *
 *  A repository nobody subscribes to owns no installation at all, so it
 *  never names a place. `repo` unknown means the page has not read the
 *  catalog yet: no answer, rather than one built on the alias alone.
 */
export function installedPlaces(
  rows: ProvenanceRow[],
  catalog: Catalog,
  /** What the subscription resolved to, as the lock records it in an
   *  installation's `source_repo`: `owner/repo` for a remote, the canonical
   *  slashed path for a path source. `MarketplaceRow.provenance`, or the
   *  summary's. Not the declaration's `repo`, which a path subscription
   *  does not have, nor its `path`, which may be relative where the record
   *  is canonical. */
  repo: string | null,
): Map<string, Scope[]> {
  const places = new Map<string, Scope[]>();
  if (catalog.by !== "subscription" || !repo) return places;
  // Scope first, so one package installed into several harnesses in one
  // place names that place once rather than once per harness.
  const scopes = new Map<string, Map<string, Scope>>();
  for (const row of rows) {
    if (row.origin.origin !== "marketplace") continue;
    if (row.origin.source !== catalog.source || row.origin.repo !== repo) {
      continue;
    }
    // The package the records establish, or the observation's own kind and
    // name where they establish none — `ProvenanceRow::package_ref`.
    const ref = row.package ?? { kind: row.kind, name: row.name };
    const key = placesKey(ref.kind, ref.name);
    const here = scopes.get(key) ?? new Map();
    here.set(scopeKey(row.scope), row.scope);
    scopes.set(key, here);
  }
  for (const [key, here] of scopes) {
    places.set(key, [...here.values()].sort(personalFirst));
  }
  return places;
}

/** Where a curated set is installed: every place holding any of its members.
 *  A set is installed in a place the moment part of it is — the card's own
 *  badge says how much — so a member that landed somewhere else still names
 *  that place. */
export function bundlePlaces(
  places: Map<string, Scope[]>,
  members: { kind: string; name: string }[],
): Scope[] {
  const held = new Map<string, Scope>();
  for (const member of members) {
    for (const scope of places.get(placesKey(member.kind, member.name)) ?? []) {
      held.set(scopeKey(scope), scope);
    }
  }
  return [...held.values()].sort(personalFirst);
}
