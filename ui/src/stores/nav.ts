import { create } from "zustand";
import type { Scope } from "@/bindings";
import type { ScopeSelection } from "@/lib/derive";
import type {
  AvailableRef,
  BundleRef,
  HistoryEntry,
  LibraryFilter,
  MarketplaceRef,
  MarketplacesTab,
  PackageRef,
  PackageView,
  Page,
} from "./nav-types";

export type * from "./nav-types";

// Small and fixed so a long session of cross-page hops never grows the
// stack unbounded — nobody needs to back up more than this in practice.
const HISTORY_CAP = 20;

/** Whether the current page has a search box on screen right now — the
 * Library always does; the Marketplaces page only on its Packages tab. */
function searchBoxOnScreen(state: { page: Page; marketplacesTab: string }) {
  if (state.page === "library") return true;
  return state.page === "marketplaces" && state.marketplacesTab === "packages";
}

interface NavState {
  page: Page;
  /** Which locations the Library's table shows. It belongs to that page —
   *  every other page states the location on each row instead, so nothing
   *  is ever hidden behind a filter set somewhere else. */
  libraryScope: ScopeSelection;
  /** What the Library's search box holds, kept here so leaving the page and
   * coming back — by the sidebar, by back, or from a package page — keeps the
   * table narrowed the same way. A link into the Library states the whole
   * view it wants instead, so following one clears it. */
  search: string;
  /** Bumped whenever something asks for the search box. The mounted box
   * focuses itself on every change, so the "/" shortcut reaches whichever
   * search box is on screen. */
  searchFocus: number;
  marketplacesTab: MarketplacesTab;
  /** Consumed once by the Library on mount, then cleared. */
  libraryFilter: LibraryFilter | null;
  /** Which package the package page shows; null anywhere else. */
  packageRef: PackageRef | null;
  marketplaceRef: MarketplaceRef | null;
  bundleRef: BundleRef | null;
  availableRef: AvailableRef | null;
  /** Which place the unmanaged page is listing. Every way in names one —
   *  the page is a project card's own list, not a machine-wide inbox. */
  unmanagedScope: Scope | null;
  /** Consumed once by the package page on mount, then cleared. */
  packageView: PackageView | null;
  history: HistoryEntry[];
  /** Where back has been from, newest last — the other half of a browser's
   * pair. Any fresh navigation abandons it, exactly as a browser does. */
  future: HistoryEntry[];
  setPage: (page: Page) => void;
  setLibraryScope: (scope: ScopeSelection) => void;
  setSearch: (search: string) => void;
  /** Focus the search box on screen, or the Library's if this page has none. */
  focusSearch: () => void;
  goToLibrary: (opts?: LibraryFilter) => void;
  /** A cross-page link from chrome that's always on screen (e.g. the status
   * footer) — pushes history like the other goTo* helpers so back and the
   * breadcrumb work, without needing per-tab state of its own. */
  goTo: (page: Page) => void;
  goToPackage: (ref: PackageRef, view?: PackageView) => void;
  goToMarketplaces: (tab?: MarketplacesTab) => void;
  /** Leave a marketplace page that has stopped existing, without recording
   * the departure. Every other `goTo*` pushes the page it leaves, which is
   * right for a page a reader chose to leave and wrong for one deleted
   * under them: Back would remount a subscription that is gone, on a dead
   * alias over a failing read. The entry that came before this page stays,
   * so Back still goes where the reader actually was. */
  leaveMarketplace: (tab?: MarketplacesTab) => void;
  goToMarketplace: (ref: MarketplaceRef) => void;
  goToBundle: (ref: BundleRef) => void;
  goToAvailablePackage: (ref: AvailableRef) => void;
  goToUnmanaged: (scope: Scope) => void;
  clearLibraryFilter: () => void;
  clearPackageView: () => void;
  back: () => void;
  forward: () => void;
}

export const useNavStore = create<NavState>((set) => ({
  page: "home",
  libraryScope: "all",
  search: "",
  searchFocus: 0,
  marketplacesTab: "subscribed",
  libraryFilter: null,
  packageRef: null,
  marketplaceRef: null,
  bundleRef: null,
  availableRef: null,
  unmanagedScope: null,
  packageView: null,
  history: [],
  future: [],
  // A direct page pick starts a fresh navigation context — an old back
  // trail pointing at a page the user deliberately left is a bug, not a
  // shortcut, and a stale filter from before the jump shouldn't resurface.
  setPage: (page) =>
    set({
      page,
      history: [],
      future: [],
      libraryFilter: null,
      packageRef: null,
      marketplaceRef: null,
      bundleRef: null,
      availableRef: null,
      unmanagedScope: null,
    }),
  setLibraryScope: (libraryScope) => set({ libraryScope }),
  setSearch: (search) => set({ search }),
  // Asking to search means "find me this thing": the box on screen answers
  // where there is one, and the Library answers everywhere else.
  focusSearch: () =>
    set((state) => ({
      ...(searchBoxOnScreen(state)
        ? {}
        : {
            page: "library" as const,
            history: pushHistory(state, "library"),
            future: [],
          }),
      searchFocus: state.searchFocus + 1,
    })),
  // Always a handoff, even an empty one: a link that names no filter is
  // asking for everything, and the Library has to be able to tell that
  // apart from arriving with no link at all, where the stored view stands.
  goToLibrary: ({ harness, kind, scope } = {}) =>
    set((state) => ({
      page: "library",
      libraryFilter: { harness, kind, scope },
      history: pushHistory(state, "library"),
      future: [],
    })),
  goTo: (page) =>
    set((state) => ({
      page,
      history: pushHistory(state, page),
      future: [],
    })),
  goToPackage: (ref, view) =>
    set((state) => ({
      page: "package",
      packageRef: ref,
      packageView: view ?? null,
      history: pushHistory(state, "package"),
      future: [],
    })),
  goToMarketplaces: (tab) =>
    set((state) => ({
      page: "marketplaces",
      ...(tab ? { marketplacesTab: tab } : {}),
      history: pushHistory(state, "marketplaces"),
      future: [],
    })),
  // Not `pushHistory`: the page being left no longer exists, so it must
  // not become somewhere Back can return to. History and future are left
  // exactly as they are.
  leaveMarketplace: (tab) =>
    set((state) => ({
      page: "marketplaces",
      ...(tab ? { marketplacesTab: tab } : {}),
      history: state.history,
      future: state.future,
    })),
  goToMarketplace: (ref) =>
    set((state) => ({
      page: "marketplaceDetail",
      marketplaceRef: ref,
      history: pushHistory(state, "marketplaceDetail"),
      future: [],
    })),
  goToBundle: (ref) =>
    set((state) => ({
      page: "bundleDetail",
      bundleRef: ref,
      history: pushHistory(state, "bundleDetail"),
      future: [],
    })),
  goToAvailablePackage: (ref) =>
    set((state) => ({
      page: "availablePackage",
      availableRef: ref,
      history: pushHistory(state, "availablePackage"),
      future: [],
    })),
  goToUnmanaged: (scope) =>
    set((state) => ({
      page: "unmanaged",
      unmanagedScope: scope,
      history: pushHistory(state, "unmanaged"),
      future: [],
    })),
  clearLibraryFilter: () => set({ libraryFilter: null }),
  clearPackageView: () => set({ packageView: null }),
  back: () =>
    set((state) => {
      const prior = state.history.at(-1);
      if (!prior) return state;
      return {
        ...prior,
        libraryFilter: null,
        packageView: null,
        history: state.history.slice(0, -1),
        future: [...state.future, here(state)].slice(-HISTORY_CAP),
      };
    }),
  forward: () =>
    set((state) => {
      const next = state.future.at(-1);
      if (!next) return state;
      return {
        ...next,
        libraryFilter: null,
        packageView: null,
        history: [...state.history, here(state)].slice(-HISTORY_CAP),
        future: state.future.slice(0, -1),
      };
    }),
}));

/** The entry describing where the user is standing right now. */
function here(state: NavState): HistoryEntry {
  return {
    page: state.page,
    marketplacesTab: state.marketplacesTab,
    packageRef: state.packageRef,
    marketplaceRef: state.marketplaceRef,
    bundleRef: state.bundleRef,
    availableRef: state.availableRef,
    unmanagedScope: state.unmanagedScope,
  };
}

// Only a real page change is worth a stack entry — switching tabs within
// the page you're already on isn't a "place" to come back to.
function pushHistory(state: NavState, destination: Page): HistoryEntry[] {
  if (state.page === destination) return state.history;
  return [...state.history, here(state)].slice(-HISTORY_CAP);
}
