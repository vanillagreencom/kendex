import { useMemo } from "react";
import type { Scope } from "@/bindings";
import {
  type CustomizedHere,
  customizedHere,
  indexCustomized,
  indexRows,
} from "@/lib/customized-places";
import type { Draft } from "@/lib/editor-draft";
import { scopeKey } from "@/lib/scope";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";

/** The Customize page's index for the place it is editing.
 *
 *  The open draft stands in for that place's saved manifest: a setting
 *  removed here and not yet saved leaves the list at once, as the Remove
 *  control promises, and one typed on a package's own page joins it. Hand
 *  edits and forks are read from the same rows the Library reads. */
export function useCustomizedHere(
  draft: Draft | null,
  scope: Scope,
): CustomizedHere[] {
  const saved = useEditorStore((s) => s.saved);
  const rows = useUpdatesStore((s) => s.rows);
  const updatesLoaded = useUpdatesStore((s) => s.loaded);
  return useMemo(() => {
    const manifests = draft ? { ...saved, [scopeKey(scope)]: draft } : saved;
    return customizedHere(
      {
        manifests,
        rows: indexRows(rows),
        updatesLoaded,
        settings: indexCustomized(manifests),
      },
      scope,
    );
  }, [draft, saved, rows, updatesLoaded, scope]);
}
