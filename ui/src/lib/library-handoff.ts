import type { ScopeSelection } from "@/lib/derive";
import { type FilterSelection, NO_FILTERS } from "@/stores/library-view";
import type { LibraryFilter } from "@/stores/nav-types";

/** Everything the Library's table is showing: the narrowing its filter strip
 * holds, what the search box holds, and where it is looking. The strip's own
 * fields stay grouped as the store defines them rather than being restated
 * here, so a filter added to the strip is part of the view by construction. */
export interface LibraryView {
  filters: FilterSelection;
  search: string;
  scope: ScopeSelection;
}

/** Everything, everywhere: nothing narrowed, nothing searched for, every
 * location in view. */
export const UNFILTERED: LibraryView = {
  filters: NO_FILTERS,
  search: "",
  scope: "all",
};

/** Whether a view is holding anything back, which is what makes offering to
 * clear it worth doing. Compared against {@link UNFILTERED} rather than
 * tested field by field, so a filter added to the strip counts here too. */
export function isNarrowed(view: LibraryView): boolean {
  if (view.search !== UNFILTERED.search || view.scope !== UNFILTERED.scope) {
    return true;
  }
  const names = Object.keys(NO_FILTERS) as (keyof FilterSelection)[];
  return names.some((name) => view.filters[name] !== NO_FILTERS[name]);
}

/**
 * The view the Library should adopt for a link that just opened it, or null
 * when it was opened some other way and the stored view stands.
 *
 * A link states the whole view it wants, so everything it does not name goes
 * back to unfiltered rather than carrying over: otherwise "everything in this
 * project" arrives still narrowed to the last kind, tag or search an earlier
 * visit left behind.
 */
export function libraryViewFromHandoff(
  handoff: LibraryFilter | null,
): LibraryView | null {
  if (!handoff) return null;
  return {
    filters: {
      ...NO_FILTERS,
      kind: handoff.kind ?? NO_FILTERS.kind,
      harness: handoff.harness ?? NO_FILTERS.harness,
    },
    search: UNFILTERED.search,
    scope: handoff.scope ?? UNFILTERED.scope,
  };
}
