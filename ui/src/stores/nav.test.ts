import { beforeEach, describe, expect, it } from "vitest";
import { useNavStore } from "./nav";

describe("nav store", () => {
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

  const GH = {
    kind: "skill" as const,
    name: "gh",
    scope: { scope: "global" as const },
  };

  it("opens a package, remembers it through back, and clears on a direct pick", () => {
    useNavStore.getState().goToLibrary();
    useNavStore.getState().goToPackage(GH);

    let state = useNavStore.getState();
    expect(state.page).toBe("package");
    expect(state.packageRef).toEqual(GH);

    state.back();
    state = useNavStore.getState();
    expect(state.page).toBe("library");
    expect(state.packageRef).toBeNull();

    useNavStore.getState().goToPackage(GH);
    useNavStore.getState().setPage("home");
    expect(useNavStore.getState().packageRef).toBeNull();
    expect(useNavStore.getState().history).toEqual([]);
  });

  it("walks back and forward over the same trail, like a browser", () => {
    useNavStore.getState().goToLibrary();
    useNavStore.getState().goToPackage(GH);

    useNavStore.getState().back();
    expect(useNavStore.getState().page).toBe("library");
    useNavStore.getState().back();
    expect(useNavStore.getState().page).toBe("home");

    useNavStore.getState().forward();
    expect(useNavStore.getState().page).toBe("library");
    useNavStore.getState().forward();

    const state = useNavStore.getState();
    expect(state.page).toBe("package");
    expect(state.packageRef).toEqual(GH);
    expect(state.future).toEqual([]);
  });

  it("abandons the forward trail once a new page is opened", () => {
    useNavStore.getState().goToLibrary();
    useNavStore.getState().back();
    expect(useNavStore.getState().future).toHaveLength(1);

    useNavStore.getState().goTo("harnesses");
    expect(useNavStore.getState().future).toEqual([]);
  });

  it("does nothing at either end of the trail", () => {
    useNavStore.getState().forward();
    expect(useNavStore.getState().page).toBe("home");
    useNavStore.getState().back();
    expect(useNavStore.getState().page).toBe("home");
  });

  it("re-asking for the search box on the Library refocuses without navigating", () => {
    useNavStore.getState().focusSearch();
    const pushed = useNavStore.getState().history;
    useNavStore.getState().focusSearch();

    const state = useNavStore.getState();
    expect(state.searchFocus).toBe(2);
    expect(state.history).toEqual(pushed);
  });

  it("keeps the search text while moving between pages", () => {
    useNavStore.getState().setSearch("deploy");
    useNavStore.getState().goToPackage(GH);

    expect(useNavStore.getState().search).toBe("deploy");
  });

  it("carries an initial diff view to the package page, consumed once", () => {
    useNavStore
      .getState()
      .goToPackage(GH, { mode: "diff", from: "aaa", to: "bbb" });
    expect(useNavStore.getState().packageView).toEqual({
      mode: "diff",
      from: "aaa",
      to: "bbb",
    });
    useNavStore.getState().clearPackageView();
    expect(useNavStore.getState().packageView).toBeNull();
  });

  it("hands off a tool + kind filter to Library and clears it on request", () => {
    useNavStore.getState().goToLibrary({ harness: "claude", kind: "hook" });

    const state = useNavStore.getState();
    expect(state.page).toBe("library");
    expect(state.libraryFilter).toEqual({ harness: "claude", kind: "hook" });

    state.clearLibraryFilter();
    expect(useNavStore.getState().libraryFilter).toBeNull();
  });

  it("hands off an empty filter when a link asks for everything", () => {
    useNavStore.getState().goToLibrary({ kind: "hook" });
    useNavStore.getState().clearLibraryFilter();

    // A link naming no filter still hands off, so the Library knows to drop
    // what an earlier visit left narrowed rather than keeping "hook".
    useNavStore.getState().goToLibrary();
    expect(useNavStore.getState().libraryFilter).toEqual({
      harness: undefined,
      kind: undefined,
    });
  });

  it("pushes the prior page onto history on a cross-page nav", () => {
    useNavStore.getState().goToLibrary();

    expect(useNavStore.getState().history).toEqual([
      {
        page: "home",
        marketplacesTab: "subscribed",
        packageRef: null,
        marketplaceRef: null,
        bundleRef: null,
        availableRef: null,
      },
    ]);
  });

  it("back() pops history and restores the prior page and tab", () => {
    useNavStore.setState({ marketplacesTab: "packages" });
    useNavStore.getState().goTo("harnesses");
    useNavStore.getState().back();

    const state = useNavStore.getState();
    expect(state.page).toBe("home");
    expect(state.marketplacesTab).toBe("packages");
    expect(state.history).toEqual([]);
  });

  it("back() clears any pending library filter", () => {
    useNavStore.getState().goTo("harnesses");
    useNavStore.getState().goToLibrary({ harness: "claude", kind: "hook" });
    useNavStore.getState().back();

    expect(useNavStore.getState().libraryFilter).toBeNull();
  });

  it("is a no-op when history is empty", () => {
    useNavStore.getState().back();

    expect(useNavStore.getState().page).toBe("home");
  });

  it("setPage resets the history stack and clears any pending filter", () => {
    useNavStore.getState().goToLibrary({ harness: "claude", kind: "hook" });
    useNavStore.getState().setPage("settings");

    const state = useNavStore.getState();
    expect(state.history).toEqual([]);
    expect(state.libraryFilter).toBeNull();
  });

  it("goTo pushes history like the other cross-page helpers", () => {
    useNavStore.getState().goTo("review");

    const state = useNavStore.getState();
    expect(state.page).toBe("review");
    expect(state.history).toEqual([
      {
        page: "home",
        marketplacesTab: "subscribed",
        packageRef: null,
        marketplaceRef: null,
        bundleRef: null,
        availableRef: null,
      },
    ]);
  });

  it("back() after goTo restores the page it was called from", () => {
    useNavStore.getState().goTo("projects");
    useNavStore.getState().goTo("review");
    useNavStore.getState().back();

    expect(useNavStore.getState().page).toBe("projects");
  });

  it("caps the history stack so it never grows without bound", () => {
    for (let i = 0; i < 25; i++) {
      useNavStore.getState().goToLibrary();
      useNavStore.getState().goTo("harnesses");
    }

    expect(useNavStore.getState().history.length).toBeLessThanOrEqual(20);
  });
});
