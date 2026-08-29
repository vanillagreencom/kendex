import { useMemo } from "react";
import type { Scope } from "@/bindings";
import {
  type CustomizedHere,
  customizedHere,
  manifestsForEditing,
  placesSource,
} from "@/lib/customized-places";
import type { Draft } from "@/lib/editor-draft";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";

/** The Customize page's index for the place it is editing: the open draft
 *  for settings, the same update rows the Library reads for hand edits
 *  and forks. */
export function useCustomizedHere(
  draft: Draft | null,
  scope: Scope,
): CustomizedHere[] {
  const saved = useEditorStore((s) => s.saved);
  const settings = useEditorStore((s) => s.savedSettings);
  const rows = useUpdatesStore((s) => s.rows);
  const updatesLoaded = useUpdatesStore((s) => s.loaded);
  return useMemo(
    () =>
      customizedHere(
        placesSource(
          manifestsForEditing(saved, draft, scope),
          rows,
          updatesLoaded,
          settings,
        ),
        scope,
      ),
    [draft, saved, rows, updatesLoaded, settings, scope],
  );
}
