import { beforeEach, describe, expect, it } from "vitest";
import { useNavStore } from "./nav";

// The Marketplaces half of navigation: its tab memory, the nested refs, and
// where the "/" shortcut lands when more than one page holds a search box.
describe("nav store — marketplaces", () => {
  beforeEach(() => {
    useNavStore.setState({
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
      packageView: null,
      history: [],
      future: [],
    });
  });

  it("focuses the search box belonging to the current page", () => {
    const rows = [
      {
        name: "page without search",
        open: () => useNavStore.getState().goTo("harnesses"),
        page: "library",
        focus: 1,
      },
      {
        name: "packages tab",
        open: () => useNavStore.getState().goToMarketplaces("packages"),
        page: "marketplaces",
        focus: 1,
      },
      {
        name: "subscribed tab",
        open: () => useNavStore.getState().goToMarketplaces("subscribed"),
        page: "library",
        focus: null,
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      useNavStore.setState({ searchFocus: 0 });
      row.open();
      useNavStore.getState().focusSearch();
      const state = useNavStore.getState();
      expect(state.page, row.name).toBe(row.page);
      if (row.focus !== null)
        expect(state.searchFocus, row.name).toBe(row.focus);
    }
  });

  it("remembers which Marketplaces tab was open through back", () => {
    useNavStore.getState().goToMarketplaces("packages");
    useNavStore.getState().goToMarketplace({
      by: "subscription",
      scope: { scope: "global" },
      source: "kendex",
    });
    useNavStore.getState().back();

    const state = useNavStore.getState();
    expect(state.page).toBe("marketplaces");
    expect(state.marketplacesTab).toBe("packages");
  });

  it("opens nested marketplace pages with their refs, cleared on a pick", () => {
    const ref = {
      by: "subscription" as const,
      scope: { scope: "global" as const },
      source: "kendex",
    };
    useNavStore.getState().goToMarketplace(ref);
    expect(useNavStore.getState().marketplaceRef).toEqual(ref);

    useNavStore.getState().goToBundle({ catalog: ref, bundle: "starter" });
    expect(useNavStore.getState().page).toBe("bundleDetail");

    useNavStore.getState().setPage("home");
    expect(useNavStore.getState().marketplaceRef).toBeNull();
    expect(useNavStore.getState().bundleRef).toBeNull();
  });

  it("does not push when goToMarketplaces only switches tabs", () => {
    useNavStore.getState().goToMarketplaces();
    useNavStore.getState().goToMarketplaces("packages");

    expect(useNavStore.getState().history).toHaveLength(1);
  });

  // A marketplace page whose last subscription was just removed does not
  // exist any more. Departing through a pushing helper would record it,
  // and Back would remount a deleted subscription — a dead alias in the
  // header over a failing read. It is left, not navigated away from: what
  // came before it is still where Back goes.
  it("does not send Back to a marketplace that was just removed", () => {
    useNavStore.getState().goTo("harnesses");
    useNavStore.getState().goToMarketplace({
      by: "subscription",
      scope: { scope: "global" },
      source: "kit",
    });

    useNavStore.getState().leaveMarketplace("subscribed");
    expect(useNavStore.getState().page).toBe("marketplaces");

    useNavStore.getState().back();

    const state = useNavStore.getState();
    expect(state.page).not.toBe("marketplaceDetail");
    expect(state.page).toBe("harnesses");
  });
});
