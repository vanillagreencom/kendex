import { useEffect, useMemo } from "react";
import type { Catalog, Scope } from "@/bindings";
import { installedPlaces } from "@/lib/installed-places";
import { useProvenanceStore } from "@/stores/provenance";

/** A stable empty list, so a page that never reads the provenance join does
 *  not take a fresh array identity on every store read. */
const EMPTY_ROWS: never[] = [];

/** Where each of one marketplace's packages is installed, for every surface
 *  on that marketplace's page. One read and one pass over the join, so the
 *  Bundles tab and the Packages tab answer from the same rows rather than
 *  scanning every installation on the machine twice.
 *
 *  Keeping the rows current afterwards is not this hook's job, and an
 *  install landing on screen is no proof of it: a redirected install writes
 *  its rows under the destination's key. `lib/rescan.ts` refreshes the join
 *  behind every write, and the rows arrive here as a store read like any
 *  other. */
export function useInstalledPlaces(
  catalog: Catalog,
  /** What the subscription resolved to, as the lock records it. Null until
   *  the catalog has been read, which is no answer rather than an answer
   *  built on the alias alone. */
  repo: string | null,
): Map<string, Scope[]> {
  // A repository nobody subscribes to owns no installation, so its page
  // neither reads the join nor re-renders on it.
  const wanted = catalog.by === "subscription" && repo !== null;
  const rows = useProvenanceStore((s) => (wanted ? s.rows : EMPTY_ROWS));
  const reload = useProvenanceStore((s) => s.reload);
  useEffect(() => {
    if (wanted) void reload();
  }, [wanted, reload]);
  return useMemo(
    () => installedPlaces(rows, catalog, repo),
    [rows, catalog, repo],
  );
}
