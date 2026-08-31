import { useEffect, useMemo } from "react";
import type { ScopeSettings, UpdateRow } from "@/bindings";
import { placeStandings, placesSource } from "@/lib/customized-places";
import type { ItemGroup } from "@/lib/derive";
import { groupScopes } from "@/lib/derive";
import type { Draft } from "@/lib/editor-draft";
import { type PlaceMark, packageMark } from "@/lib/place-marks";
import { scopeKey } from "@/lib/scope";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";

/** The mark for one package, over every place it is installed.
 *
 *  No place is passed in on purpose: the page names a place, but the mark
 *  is about the package. Answering for the one place the page happened to
 *  open at is what let the Library and this page state two different
 *  facts under the same words. */
export function markFor(
  saved: Record<string, Draft>,
  rows: UpdateRow[],
  updatesLoaded: boolean,
  settings: Record<string, ScopeSettings>,
  group: ItemGroup,
): PlaceMark | null {
  return packageMark(
    placeStandings(
      placesSource(saved, rows, updatesLoaded, settings),
      group.kind,
      group.name,
      groupScopes(group),
    ),
  );
}

/** Takes the group as it is, absent included: the page reads this before
 *  it knows whether the scan has the package, and a hook that can only be
 *  called once that is settled is a hook called conditionally.
 *
 *  Reads the manifests it counts rather than trusting whatever a page
 *  happened to open. The editor holds one place at a time, and a mark
 *  drawn over the places nobody read is the answer the header used to
 *  give — right about one place and silent about the rest. */
export function usePackageMark(group: ItemGroup | null): PlaceMark | null {
  const saved = useEditorStore((s) => s.saved);
  const settings = useEditorStore((s) => s.savedSettings);
  const loadPlaces = useEditorStore((s) => s.loadPlaces);
  const rows = useUpdatesStore((s) => s.rows);
  const updatesLoaded = useUpdatesStore((s) => s.read.status === "landed");
  // The scan rebuilds the group on every read, so what is held onto is
  // which places those are, not the array they arrived in.
  const scopes = group ? groupScopes(group) : [];
  const key = scopes.map(scopeKey).join("|");
  // biome-ignore lint/correctness/useExhaustiveDependencies: which places, not which array
  const places = useMemo(() => scopes, [key]);
  useEffect(() => {
    if (places.length > 0) void loadPlaces(places);
  }, [places, loadPlaces]);
  if (!group) return null;
  return markFor(saved, rows, updatesLoaded, settings, group);
}
