import { create } from "zustand";

/** What the Installed table's filter strip is narrowing by. Values use the
 * strip's own vocabulary: "any" means unfiltered. */
export interface LibraryFilters {
  kind: string;
  harness: string;
  tag: string;
  from: string;
}

/** Narrowed by nothing. The one definition of an unfiltered strip, so the
 * table's opening state, its Clear affordance and a link asking for
 * everything can never drift apart on what "everything" means. */
export const NO_FILTERS: LibraryFilters = {
  kind: "any",
  harness: "any",
  tag: "any",
  from: "any",
};

/** The Installed table's view state, kept outside the component so opening
 * a package (a real page, which unmounts the table) and coming back lands
 * on the same filters and the same scroll position. Where an item lives is
 * not here — that is the app-wide scope, so the table and the rest of the
 * app can never disagree about which project is being looked at.
 * Session-lifetime only — a fresh launch starts clean, like every other
 * filter in the app. */
interface LibraryViewState extends LibraryFilters {
  /** The table's scroll offset when it last unmounted. */
  scrollTop: number;
  setKind: (kind: string) => void;
  setHarness: (harness: string) => void;
  setTag: (tag: string) => void;
  setFrom: (from: string) => void;
  setScrollTop: (scrollTop: number) => void;
  /** Adopt a whole narrowing at once — a link's, or the empty one behind
   * Clear. Taken as one object rather than field by field, so a filter added
   * to the strip is applied without anyone having to remember it here. */
  setFilters: (filters: LibraryFilters) => void;
}

export const useLibraryViewStore = create<LibraryViewState>((set) => ({
  ...NO_FILTERS,
  scrollTop: 0,
  setKind: (kind) => set({ kind }),
  setHarness: (harness) => set({ harness }),
  setTag: (tag) => set({ tag }),
  setFrom: (from) => set({ from }),
  setScrollTop: (scrollTop) => set({ scrollTop }),
  setFilters: (filters) => set(filters),
}));
