import { useEffect } from "react";
import { useLibraryViewStore } from "@/stores/library-view";
import { useNavStore } from "@/stores/nav";

/**
 * Apply the filter a link into the Library asked for, once, on arrival.
 *
 * The handoff comes from wherever the link was clicked — Harnesses,
 * Projects, Home — and a link states the whole narrowing it wants, so
 * whatever an earlier visit left behind goes first: otherwise "everything
 * in this project" arrives still narrowed to the last kind looked at.
 * Where to look is not part of it — the caller sets the scope on the way
 * here. Arriving with no link at all leaves the stored view standing.
 */
export function useFilterHandoff() {
  const clearLibraryFilter = useNavStore((s) => s.clearLibraryFilter);
  const setSearch = useNavStore((s) => s.setSearch);
  const setKind = useLibraryViewStore((s) => s.setKind);
  const setHarness = useLibraryViewStore((s) => s.setHarness);
  const clearViewFilters = useLibraryViewStore((s) => s.clearFilters);

  useEffect(() => {
    const handoff = useNavStore.getState().libraryFilter;
    if (handoff) {
      clearViewFilters();
      setSearch("");
      setKind(handoff.kind ?? "any");
      setHarness(handoff.harness ?? "any");
    }
    clearLibraryFilter();
  }, [clearLibraryFilter, clearViewFilters, setSearch, setKind, setHarness]);
}
