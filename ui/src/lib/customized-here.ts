import { useMemo } from "react";
import type { Scope } from "@/bindings";
import {
  type CustomizedHere,
  customizedHere,
  manifestsForEditing,
  placesSource,
} from "@/lib/customized-places";
import type { Draft } from "@/lib/editor-draft";
import { scopeKey } from "@/lib/scope";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";

/** The Customize page's index for the place it is editing: the open
 *  manifest draft and the settings edits in hand for that place, and the
 *  same update rows the Library reads for hand edits and forks.
 *
 *  Both drafts or neither. The page skips its reload while anything is
 *  unsaved, so an index reading only what was last saved would go on
 *  omitting a package this person has just made theirs — while the
 *  manifest half of the same page already answers from the draft. */
export function useCustomizedHere(
  draft: Draft | null,
  scope: Scope,
): CustomizedHere[] {
  const saved = useEditorStore((s) => s.saved);
  const settings = useEditorStore((s) => s.savedSettings);
  const edits = useEditorStore((s) => s.settingsEdits);
  const rows = useUpdatesStore((s) => s.rows);
  const updatesLoaded = useUpdatesStore((s) => s.read.status === "landed");
  return useMemo(
    () =>
      customizedHere(
        placesSource(
          manifestsForEditing(saved, draft, scope),
          rows,
          updatesLoaded,
          settings,
          { [scopeKey(scope)]: edits },
        ),
        scope,
      ),
    [draft, saved, rows, updatesLoaded, settings, edits, scope],
  );
}
