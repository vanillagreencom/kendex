import type { Scope, UpdateRow } from "@/bindings";
import { placeStandings, placesSource } from "@/lib/customized-places";
import type { ItemGroup } from "@/lib/derive";
import { groupScopes } from "@/lib/derive";
import type { Draft } from "@/lib/editor-draft";
import { headerMark, type PlaceMark } from "@/lib/place-marks";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";

/** The mark for one package at one place.
 *
 *  Takes the place rather than reading the editor's: the editor is pointed
 *  wherever the Customize tab was last used, and a page that names a place
 *  has to answer for the place it names. */
export function markFor(
  saved: Record<string, Draft>,
  rows: UpdateRow[],
  updatesLoaded: boolean,
  group: ItemGroup,
  scope: Scope,
): PlaceMark | null {
  return headerMark(
    placeStandings(
      placesSource(saved, rows, updatesLoaded),
      group.kind,
      group.name,
      groupScopes(group),
    ),
    scope,
  );
}

/** Takes the group and place as they are, absent included: the page reads
 *  this before it knows whether the scan has the package, and a hook that
 *  can only be called once that is settled is a hook called conditionally. */
export function usePackageMark(
  group: ItemGroup | null,
  scope: Scope | null,
): PlaceMark | null {
  const saved = useEditorStore((s) => s.saved);
  const rows = useUpdatesStore((s) => s.rows);
  const updatesLoaded = useUpdatesStore((s) => s.loaded);
  if (!group || !scope) return null;
  return markFor(saved, rows, updatesLoaded, group, scope);
}
