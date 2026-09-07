import { useMemo } from "react";
import {
  type PlaceStanding,
  placeFacts,
  placeStandings,
  placesSource,
} from "@/lib/customized-places";
import type { ItemGroup } from "@/lib/derive";
import { groupScopes } from "@/lib/derive";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";

/** How every package on screen stands in every place it is installed.
 *
 *  Built once for the whole table rather than per row: reading a place's
 *  customizations walks its whole manifest, and the mark, the fork badges
 *  and the legend all ask the same question of the same rows. */
export function useLibraryStandings(groups: ItemGroup[]): {
  standingsFor: (group: ItemGroup) => PlaceStanding[];
  /** Whether the package's installed files were edited on disk in any
   *  place — the same per-place fact the standings read, asked on its
   *  own because a fork or a settings overlay outranks it in a standing.
   *  Null until the updates read has landed: nothing has been counted
   *  yet, which is not the same as nothing edited. */
  editedAnywhere: ((group: ItemGroup) => boolean) | null;
} {
  const saved = useEditorStore((s) => s.saved);
  const savedSettings = useEditorStore((s) => s.savedSettings);
  const updateRows = useUpdatesStore((s) => s.rows);
  const updatesLoaded = useUpdatesStore((s) => s.read.status === "landed");
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
  return {
    standingsFor: (group: ItemGroup) => byKey.get(group.key) ?? [],
    editedAnywhere,
  };
}
