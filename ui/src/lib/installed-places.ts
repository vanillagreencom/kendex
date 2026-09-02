import type { Catalog, ProvenanceRow } from "@/bindings";
import { listed } from "@/lib/listed";
import { scopeKey } from "@/lib/scope";
import { placeName } from "@/lib/update-groups";

/** One offered package's identity in the places index.
 *
 *  Joined with `::`, the way `stores/preinstall-safety.ts::safetyKey`
 *  already keys the same pair for the same rows — `packages-table.tsx`
 *  calls both on one row, and one keying convention beats two. A name
 *  cannot carry `::`: every offered name passes `names::item_problem`
 *  before the catalog offers it. */
export const placesKey = (kind: string, name: string): string =>
  `${kind}::${name}`;

/** Where each of a marketplace's packages is installed from, worded, keyed
 *  by kind and name.
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
 *  project from a personal subscription is exactly what this column exists
 *  to name, and joining on scope would drop it.
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
): Map<string, string> {
  const places = new Map<string, string>();
  if (catalog.by !== "subscription" || !repo) return places;
  // Scope first, so one package installed into several harnesses in one
  // place names that place once rather than once per harness.
  const scopes = new Map<string, Map<string, ProvenanceRow["scope"]>>();
  for (const row of rows) {
    if (row.origin.origin !== "marketplace") continue;
    if (row.origin.source !== catalog.source || row.origin.repo !== repo) {
      continue;
    }
    const key = placesKey(row.kind, row.name);
    const here = scopes.get(key) ?? new Map();
    here.set(scopeKey(row.scope), row.scope);
    scopes.set(key, here);
  }
  for (const [key, here] of scopes) {
    const all = [...here.values()];
    places.set(key, listed(all.map((scope) => placeName(scope, all))));
  }
  return places;
}
