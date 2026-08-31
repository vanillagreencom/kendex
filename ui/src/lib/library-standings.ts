import { useMemo } from "react";
import {
  type PlaceStanding,
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
export function useLibraryStandings(
  groups: ItemGroup[],
): (group: ItemGroup) => PlaceStanding[] {
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
  return (group: ItemGroup) => byKey.get(group.key) ?? [];
}
