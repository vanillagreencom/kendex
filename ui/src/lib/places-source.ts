import { useMemo } from "react";
import type { Draft } from "@/lib/editor-draft";
import { useEditorStore } from "@/stores/editor";
import { whyUnread } from "@/stores/editor-order";
import { updatesReading, useUpdatesStore } from "@/stores/updates";
import {
  indexRows,
  manifestsOnScreen,
  type PlacesSource,
  readState,
} from "./customized-places";

/** Everything both variants read, and the identity of what it builds. The
 *  stores hand back their previous value when a re-read says the same
 *  thing, so this changes only when a fact does. */
function useJoined(manifests: Record<string, Draft>): PlacesSource {
  const manifestsLoaded = useEditorStore((s) => s.manifestsLoaded);
  const rows = useUpdatesStore((s) => s.rows);
  const updatesLoaded = useUpdatesStore((s) => s.loaded);
  const updatesError = useUpdatesStore((s) => s.error);
  const indexed = useMemo(() => indexRows(rows), [rows]);
  const updatesRead = readState(updatesLoaded, updatesError);
  const unread = useEditorStore((s) => s.unreadPlaces);
  const manifestsRead = readState(manifestsLoaded, useEditorStore(whyUnread));
  const manifestsReading = useEditorStore((s) => s.manifestsReading);
  const reading = useUpdatesStore(updatesReading);
  const unreadPlaces = useMemo(() => new Set(Object.keys(unread)), [unread]);
  return useMemo(
    () => ({
      manifests,
      rows: indexed,
      updatesRead,
      manifestsRead,
      unreadPlaces,
      manifestsReading,
      updatesReading: reading,
    }),
    [
      manifests,
      indexed,
      updatesRead,
      manifestsRead,
      unreadPlaces,
      manifestsReading,
      reading,
    ],
  );
}

/** What is actually customized: saved manifests and the update standing.
 *  The Library's question, and the one a mark on a row answers. Deliberately
 *  no subscription to the draft — a keystroke in the editor is not news
 *  here, and this is what the whole Library table joins on. */
export function usePlacesSource(): PlacesSource {
  return useJoined(useEditorStore((s) => s.saved));
}

/** The same, with the manifest being typed overlaid on the place it
 *  belongs to — so the header, the chips and the box you are typing in
 *  never disagree. Only the editor's own surfaces want this: text you have
 *  not saved has changed nothing yet. */
export function useEditingPlacesSource(): PlacesSource {
  const saved = useEditorStore((s) => s.saved);
  const scope = useEditorStore((s) => s.scope);
  const draft = useEditorStore((s) => s.draft);
  const manifests = useMemo(
    () => manifestsOnScreen(saved, scope, draft),
    [saved, scope, draft],
  );
  return useJoined(manifests);
}
