import { useMemo } from "react";
import type { Scope } from "@/bindings";
import {
  type PlaceStanding,
  placeFacts,
  placeStandings,
  placesSource,
} from "@/lib/customized-places";
import type { ItemGroup } from "@/lib/derive";
import { groupScopes } from "@/lib/derive";
import { useMissingRows } from "@/lib/missing-files";
import { availableUpdates } from "@/lib/update-groups";
import { rowsKnown } from "@/lib/updates-read-state";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";

/** How every package on screen stands in every place it is installed.
 *
 *  Built once for the whole table rather than per row: reading a place's
 *  customizations walks its whole manifest, and the fork badges and the
 *  edited facet ask the same question of the same rows. */
export function useLibraryStandings(groups: ItemGroup[]): {
  standingsFor: (group: ItemGroup) => PlaceStanding[];
  /** Whether the package's installed files were edited on disk in any
   *  place — the same per-place fact the standings read, asked on its
   *  own because a fork or a settings overlay outranks it in a standing.
   *  Null until the updates read has landed: nothing has been counted
   *  yet, which is not the same as nothing edited. */
  editedAnywhere: ((group: ItemGroup) => boolean) | null;
  /** Whether this package has an update in any place it is installed —
   *  the set Home counts and a place's card counts, so the mark and those
   *  numbers cannot come apart. A package its source dropped is not one:
   *  it has no version to move to, and the badge's words promise one.
   *  Null until a read lands: a badge is a definite claim, and rows kept
   *  from a failed check have not confirmed one. */
  outOfDateAnywhere: ((group: ItemGroup) => boolean) | null;
  /** The places where a file kendex installed for this package is gone
   *  — the rows Home's missing-files row counts, so the badge and that
   *  row cannot disagree. A local disk fact like an edit, so it is read
   *  the way `editedAnywhere` is: from rows a landed read confirmed or a
   *  failed re-check kept, and null before either. */
  missingIn: ((group: ItemGroup) => Scope[]) | null;
} {
  const saved = useEditorStore((s) => s.saved);
  const savedSettings = useEditorStore((s) => s.savedSettings);
  const updateRows = useUpdatesStore((s) => s.rows);
  const updatesLoaded = useUpdatesStore(rowsKnown);
  const updatesLanded = useUpdatesStore((s) => s.read.status === "landed");
  const places = useMemo(
    () => placesSource(saved, updateRows, updatesLoaded, savedSettings),
    [saved, updateRows, updatesLoaded, savedSettings],
  );
  const byKey = useMemo(() => {
    const out = new Map<string, PlaceStanding[]>();
    for (const group of groups)
      out.set(
        group.key,
        placeStandings(places, group.kind, group.name, groupScopes(group)),
      );
    return out;
  }, [groups, places]);
  const editedAnywhere = useMemo(
    () =>
      updatesLoaded
        ? (group: ItemGroup) =>
            groupScopes(group).some(
              (scope) =>
                placeFacts(places, group.kind, group.name, scope).edited ===
                true,
            )
        : null,
    [places, updatesLoaded],
  );
  // Keyed by kind and name, the Library's own unit: a row stands for the
  // package wherever it is installed, so an update in any one of its places
  // is an update on that row.
  const outOfDate = useMemo(
    () =>
      new Set(
        availableUpdates(updateRows).map((row) => `${row.kind}:${row.name}`),
      ),
    [updateRows],
  );
  const outOfDateAnywhere = useMemo(
    () =>
      updatesLanded
        ? (group: ItemGroup) => outOfDate.has(`${group.kind}:${group.name}`)
        : null,
    [outOfDate, updatesLanded],
  );
  // The same rows the Library's own list stands a missing package's row
  // up from, so the badge and that row can never come apart.
  const missingRows = useMissingRows();
  const missing = useMemo(() => {
    const out = new Map<string, Scope[]>();
    for (const row of missingRows) {
      const key = `${row.kind}:${row.name}`;
      out.set(key, [...(out.get(key) ?? []), row.scope]);
    }
    return out;
  }, [missingRows]);
  const missingIn = useMemo(
    () =>
      updatesLoaded
        ? (group: ItemGroup) => missing.get(`${group.kind}:${group.name}`) ?? []
        : null,
    [missing, updatesLoaded],
  );
  return {
    standingsFor: (group: ItemGroup) => byKey.get(group.key) ?? [],
    editedAnywhere,
    outOfDateAnywhere,
    missingIn,
  };
}
