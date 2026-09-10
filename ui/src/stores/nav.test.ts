import { beforeEach, describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
import { type LibraryFilter, useNavStore } from "./nav";

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
    identity: "recorded" as const,
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

  it("hands the Library the whole filter intent of a link", () => {
    const rows: {
      name: string;
      filter: LibraryFilter | undefined;
      expected: LibraryFilter;
      clear: boolean;
    }[] = [
      {
        name: "harness and kind",
        filter: { harness: "claude", kind: "hook" },
        expected: { harness: "claude", kind: "hook" },
        clear: true,
      },
      { name: "everything", filter: undefined, expected: {}, clear: false },
      {
        name: "one project",
        filter: { scope: { project: "/x" } },
        expected: { scope: { project: "/x" } },
        clear: false,
      },
      {
        name: "personal setup",
        filter: { scope: "global" },
        expected: { scope: "global" },
        clear: false,
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      useNavStore.getState().goToLibrary(row.filter);
      const state = useNavStore.getState();
      expect(state.page, row.name).toBe("library");
      expect(state.libraryFilter, row.name).toEqual(row.expected);
      if (row.clear) {
        state.clearLibraryFilter();
        expect(useNavStore.getState().libraryFilter, row.name).toBeNull();
      }
    }
  });

  it("pushes the prior page onto history on a cross-page nav", () => {
    useNavStore.getState().goToLibrary();

    expect(useNavStore.getState().history).toEqual([
      {
        page: "home",
        marketplacesTab: "subscribed",
        libraryTab: "installed",
        templateName: null,
        packageRef: null,
        marketplaceRef: null,
        bundleRef: null,
        availableRef: null,
        unmanagedScope: null,
        changesRoot: null,
        installInto: null,
      },
    ]);
  });

  // The unmanaged list is one place's, opened from that place's card, so
  // the way in names the place the same way a package link names a package.
  it("goToUnmanaged names the place its list is about", () => {
    const scope = { scope: "project" as const, root: "/work/acme" };
    useNavStore.getState().goToUnmanaged(scope);

    const state = useNavStore.getState();
    expect(state.page).toBe("unmanaged");
    expect(state.unmanagedScope).toEqual(scope);
  });

  it("a sidebar pick drops the place a previous unmanaged list was about", () => {
    useNavStore.getState().goToUnmanaged({ scope: "global" });
    useNavStore.getState().setPage("settings");

    expect(useNavStore.getState().unmanagedScope).toBeNull();
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

  it("setPage resets the history stack and clears any pending filter", () => {
    useNavStore.getState().goToLibrary({ harness: "claude", kind: "hook" });
    useNavStore.getState().setPage("settings");

    const state = useNavStore.getState();
    expect(state.history).toEqual([]);
    expect(state.libraryFilter).toBeNull();
  });

  it("goTo pushes history like the other cross-page helpers", () => {
    useNavStore.getState().goTo("updates");

    const state = useNavStore.getState();
    expect(state.page).toBe("updates");
    expect(state.history).toEqual([
      {
        page: "home",
        marketplacesTab: "subscribed",
        libraryTab: "installed",
        templateName: null,
        packageRef: null,
        marketplaceRef: null,
        bundleRef: null,
        availableRef: null,
        unmanagedScope: null,
        changesRoot: null,
        installInto: null,
      },
    ]);
  });

  it("back() after goTo restores the page it was called from", () => {
    useNavStore.getState().goTo("projects");
    useNavStore.getState().goTo("updates");
    useNavStore.getState().back();

    expect(useNavStore.getState().page).toBe("projects");
  });

  it("caps the history stack so it never grows without bound", () => {
    for (let i = 0; i < 25; i++) {
      useNavStore.getState().goToLibrary();
      useNavStore.getState().goTo("harnesses");
    }

    expect(useNavStore.getState().history).toHaveLength(20);
  });
});

// The place a browse was begun for. Switching tabs is not navigating: the
// Marketplaces page calls goToMarketplaces to change its own tab, so a
// reader who arrived from a project's Add packages and then looked at
// Bundles is still browsing for that project. Arriving from anywhere else
// states its own answer, and every other destination clears it.
describe("the place a browse is begun for", () => {
  it("survives a tab switch and clears on a real navigation", () => {
    const acme: Scope = { scope: "project", root: "/work/acme" };
    useNavStore.setState({
      page: "projects",
      marketplacesTab: "subscribed",
      installInto: null,
    });

    useNavStore.getState().goToMarketplaces("packages", acme);
    expect(useNavStore.getState().installInto).toEqual(acme);

    // The page changing its own tab.
    useNavStore.getState().goToMarketplaces("subscribed");
    expect(useNavStore.getState().marketplacesTab).toBe("subscribed");
    expect(useNavStore.getState().installInto).toEqual(acme);

    // Leaving for a package clears it: nothing there was begun for acme.
    useNavStore.getState().goToPackage({
      kind: "skill",
      name: "gh",
      scope: acme,
      identity: "recorded",
    });
    expect(useNavStore.getState().installInto).toBeNull();

    // Arriving at Marketplaces from elsewhere with nobody named.
    useNavStore.getState().goToMarketplaces("packages");
    expect(useNavStore.getState().installInto).toBeNull();
  });

  // It is part of where the reader was, so back and forward carry it the
  // way they carry every ref. Backing out of a browse begun for one
  // project onto a page from before it must not leave that project
  // standing, where the next install would take it.
  it("is restored by back and forward, per entry", () => {
    const acme: Scope = { scope: "project", root: "/work/acme" };
    useNavStore.setState({
      page: "home",
      history: [],
      future: [],
      installInto: null,
    });

    // A page from before any browse, then a browse begun for acme.
    useNavStore.getState().goTo("projects");
    useNavStore.getState().goToMarketplaces("packages", acme);
    expect(useNavStore.getState().installInto).toEqual(acme);

    useNavStore.getState().back();
    expect(useNavStore.getState().page).toBe("projects");
    expect(useNavStore.getState().installInto).toBeNull();

    useNavStore.getState().back();
    expect(useNavStore.getState().page).toBe("home");
    expect(useNavStore.getState().installInto).toBeNull();

    // Forward returns to the browse, and to what it was begun for.
    useNavStore.getState().forward();
    useNavStore.getState().forward();
    expect(useNavStore.getState().page).toBe("marketplaces");
    expect(useNavStore.getState().installInto).toEqual(acme);
  });
});
