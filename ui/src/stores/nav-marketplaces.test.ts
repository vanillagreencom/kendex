import { beforeEach, describe, expect, it } from "vitest";
import { useNavStore } from "./nav";

// The Marketplaces half of navigation: its tab memory, the nested refs, and
// where the "/" shortcut lands now that more than one page holds a search box.
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

  it("takes the search shortcut to the Library from a page with no box", () => {
    useNavStore.getState().goTo("harnesses");
    useNavStore.getState().focusSearch();

    const state = useNavStore.getState();
    expect(state.page).toBe("library");
    expect(state.searchFocus).toBe(1);
  });

  it("keeps the page when its own search box is already on screen", () => {
    useNavStore.getState().goToMarketplaces("packages");
    useNavStore.getState().focusSearch();

    const state = useNavStore.getState();
    expect(state.page).toBe("marketplaces");
    expect(state.searchFocus).toBe(1);
  });

  it("falls through to the Library from a tab with no search box", () => {
    useNavStore.getState().goToMarketplaces("subscribed");
    useNavStore.getState().focusSearch();

    // Subscribed has no box on screen — a bumped counter would focus
    // nothing, so the shortcut goes where a search can actually happen.
    expect(useNavStore.getState().page).toBe("library");
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
  // exist any more. Departing through a pushing helper recorded it, so
  // Back remounted a deleted subscription — a dead alias in the header over
  // a failing read. It is left, not navigated away from: what came before
  // it is still where Back goes.
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
