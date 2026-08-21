import { create } from "zustand";
import type { LibraryView } from "@/lib/library-handoff";

/** The Installed table's view state, kept outside the component so opening
 * a package (a real page, which unmounts the table) and coming back lands
 * on the same filters and the same scroll position. Where an item lives is
 * not here — that is the app-wide scope, so the table and the rest of the
 * app can never disagree about which project is being looked at.
 * Session-lifetime only — a fresh launch starts clean, like every other
 * filter in the app. Values use the filter strip's own vocabulary: "any"
 * means unfiltered. */
interface LibraryViewState {
  kind: string;
  harness: string;
  tag: string;
  from: string;
  /** The table's scroll offset when it last unmounted. */
  scrollTop: number;
  setKind: (kind: string) => void;
  setHarness: (harness: string) => void;
  setTag: (tag: string) => void;
  setFrom: (from: string) => void;
  setScrollTop: (scrollTop: number) => void;
  /** Adopt the whole view a link into the Library asked for — the parts of
   * it this store owns. */
  setView: (view: LibraryView) => void;
  clearFilters: () => void;
}

export const useLibraryViewStore = create<LibraryViewState>((set) => ({
  kind: "any",
  harness: "any",
  tag: "any",
  from: "any",
  scrollTop: 0,
  setKind: (kind) => set({ kind }),
  setHarness: (harness) => set({ harness }),
  setTag: (tag) => set({ tag }),
  setFrom: (from) => set({ from }),
  setScrollTop: (scrollTop) => set({ scrollTop }),
  setView: ({ kind, harness, tag, from, scrollTop }) =>
    set({ kind, harness, tag, from, scrollTop }),
  clearFilters: () =>
    set({ kind: "any", harness: "any", tag: "any", from: "any" }),
}));
