import { useLayoutEffect, useState } from "react";
import {
  type LibraryView,
  libraryViewFromHandoff,
} from "@/lib/library-handoff";
import { useLibraryViewStore } from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";

/** Show a view: write each part of it to the store that holds that part. */
export function applyLibraryView(view: LibraryView): void {
  useLibraryViewStore.getState().setFilters(view.filters);
  const nav = useNavStore.getState();
  nav.setSearch(view.search);
  nav.setLibraryScope(view.scope);
}

/**
 * Adopt the view a link into the Library asked for, once, on arrival, and
 * say whether one did. A caller that has its own idea of where the table
 * should be — the scroll position — needs that answer: the offset a previous
 * visit left belongs to the list a link has just replaced.
 *
 * The handoff comes from wherever the link was clicked — Harnesses, Projects,
 * Home. What it means is {@link libraryViewFromHandoff}'s to decide; consuming
 * it here is what makes a later visit start from the stored view again.
 */
export function useFilterHandoff(): boolean {
  const clearLibraryFilter = useNavStore((s) => s.clearLibraryFilter);
  // Read while the handoff is still there. Consuming it below empties it, and
  // a later render must not read that emptiness as "no link opened the page".
  const [view] = useState(() =>
    libraryViewFromHandoff(useNavStore.getState().libraryFilter),
  );
  // Layout rather than passive: where the table looks decides which rows it
  // has at all, so writing the link's view after the first paint would put
  // the list being replaced on screen before the one that was asked for.
  useLayoutEffect(() => {
    if (view) applyLibraryView(view);
    clearLibraryFilter();
  }, [view, clearLibraryFilter]);
  return view !== null;
}
