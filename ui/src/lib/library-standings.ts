import { useMemo } from "react";
import type { Scope } from "@/bindings";
import {
  type PlaceStanding,
  placeFacts,
  placeStandings,
  placesSource,
} from "@/lib/customized-places";
import type { ItemGroup } from "@/lib/derive";
import { groupPlaces, packageKey } from "@/lib/derive";
import { useMissingRows } from "@/lib/missing-files";
import { availableUpdates } from "@/lib/update-groups";
import { rowsCountable, rowsKnown } from "@/lib/updates-read-state";
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
  const updatesCountable = useUpdatesStore(rowsCountable);
  const places = useMemo(
    () => placesSource(saved, updateRows, updatesLoaded, savedSettings),
    [saved, updateRows, updatesLoaded, savedSettings],
  );
  // The same rows the Library's own list stands a missing package's row up
  // from, so the badge, that row and the standings below cannot come apart.
  const missingRows = useMissingRows();
  // Keyed by the row a recorded package gets, which is the key `groupItems`
  // gave it. That key is prefixed apart from an observation's precisely so
  // a package named for what some unrecorded file happens to be called
  // cannot join that file's row, and a place set read across that line
  // would steer the Where cell, the fork badge and the row's own click.
  const missing = useMemo(() => {
    const out = new Map<string, Scope[]>();
    for (const row of missingRows ?? []) {
      const key = packageKey(row);
      out.set(key, [...(out.get(key) ?? []), row.scope]);
    }
    return out;
  }, [missingRows]);
  // Where a record says this package's copy is gone. Nothing for a row the
  // records account for nothing of: an observation answers only for
  // itself, whatever it shares a kind and a name with.
  const missingScopes = useMemo(
    () => (group: ItemGroup) =>
      group.package ? (missing.get(group.key) ?? []) : [],
    [missing],
  );
  const placesOf = useMemo(
    () => (group: ItemGroup) => groupPlaces(group, missingScopes(group)),
    [missingScopes],
  );
  const byKey = useMemo(() => {
    const out = new Map<string, PlaceStanding[]>();
    for (const group of groups)
      out.set(
        group.key,
        // Every place the row stands in, not only the observed ones: a
        // fork whose last rendering was deleted is still a fork, and its
        // badge is read off the place it was made in.
        placeStandings(places, group.kind, group.name, placesOf(group)),
      );
    return out;
  }, [groups, places, placesOf]);
  const editedAnywhere = useMemo(
    () =>
      updatesLoaded
        ? (group: ItemGroup) =>
            placesOf(group).some(
              (scope) =>
                placeFacts(places, group.kind, group.name, scope).edited ===
                true,
            )
        : null,
    [places, placesOf, updatesLoaded],
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
      updatesCountable
        ? (group: ItemGroup) => outOfDate.has(`${group.kind}:${group.name}`)
        : null,
    [outOfDate, updatesCountable],
  );
  const missingIn = useMemo(
    () => (updatesLoaded ? missingScopes : null),
    [missingScopes, updatesLoaded],
  );
  return {
    standingsFor: (group: ItemGroup) => byKey.get(group.key) ?? [],
    editedAnywhere,
    outOfDateAnywhere,
    missingIn,
  };
}
