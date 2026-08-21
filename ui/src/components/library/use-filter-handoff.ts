import { useEffect } from "react";
import { libraryViewFromHandoff } from "@/lib/library-handoff";
import { useLibraryViewStore } from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";

/**
 * Adopt the view a link into the Library asked for, once, on arrival.
 *
 * The handoff comes from wherever the link was clicked — Harnesses, Projects,
 * Home. What it means is {@link libraryViewFromHandoff}'s to decide; this
 * writes that answer to the stores holding each part of the view, then
 * consumes the handoff so a later visit starts from the stored view again.
 */
export function useFilterHandoff() {
  const clearLibraryFilter = useNavStore((s) => s.clearLibraryFilter);
  const setSearch = useNavStore((s) => s.setSearch);
  const setScope = useNavStore((s) => s.setLibraryScope);
  const setView = useLibraryViewStore((s) => s.setView);

  useEffect(() => {
    const view = libraryViewFromHandoff(useNavStore.getState().libraryFilter);
    if (view) {
      setView(view);
      setSearch(view.search);
      setScope(view.scope);
    }
    clearLibraryFilter();
  }, [clearLibraryFilter, setSearch, setScope, setView]);
}
