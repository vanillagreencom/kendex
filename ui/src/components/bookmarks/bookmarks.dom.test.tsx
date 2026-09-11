// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type {
  AvailablePackage,
  BundleDetail,
  Catalog,
  MarketplaceRow,
  SavedItem,
  Scope,
} from "@/bindings";
import { commands } from "@/bindings";
import { BookmarksView } from "@/components/bookmarks/bookmarks-view";
import { InstallDialog } from "@/components/install/install-dialog";
import { BundleCards } from "@/components/marketplaces/bundle-cards";
import { PackagesTable } from "@/components/marketplaces/packages-table";
import {
  BOOKMARKS_EMPTY,
  BOOKMARKS_UNREADABLE,
  bookmarkLabel,
  removeBookmarkLabel,
} from "@/lib/copy-bookmarks";
import {
  INSTALL_ACTION,
  installSelectedLabel,
  packageCount,
  selectedLabel,
} from "@/lib/copy-install";
import { ADD_TO_TEMPLATE_LABEL } from "@/lib/copy-templates";
import { READ_LANDED } from "@/lib/read-state";
import { useBookmarksStore } from "@/stores/bookmarks";
import { useInstallFlow } from "@/stores/install-flow";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useNavStore } from "@/stores/nav";
import { useTemplatesStore } from "@/stores/templates";
import { mount, settle } from "@/test/dom";

// A mounted row queues a safety score, and there is no backend behind
// these tests to answer it.
vi.mock("@/stores/preinstall-safety", async (importOriginal) => {
  const mod =
    await importOriginal<typeof import("@/stores/preinstall-safety")>();
  const hook = (selector?: (state: unknown) => unknown) => {
    const state = {
      ...mod.usePreinstallSafety.getState(),
      scores: {},
      want: () => {},
    };
    return selector ? selector(state) : state;
  };
  return {
    ...mod,
    usePreinstallSafety: Object.assign(hook, mod.usePreinstallSafety),
  };
});

vi.mock("@/bindings", () => ({
  commands: {
    bookmarksList: vi.fn(),
    bookmarkAdd: vi.fn(),
    bookmarkRemove: vi.fn(),
    marketplaceBundle: vi.fn(),
    installTargets: vi.fn(),
    templatesList: vi.fn(),
    templateAddMembers: vi.fn(),
    templateCreateFromSelection: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const CATALOG: Catalog = {
  by: "subscription",
  scope: { scope: "global" },
  source: "their-name-for-it",
};

/** The subscription row the catalog above is declared by. Its reference
 *  and the folded identity beside it are what core hands the window, and a
 *  bookmark saves the first and is compared on the second. */
const SUBSCRIPTION: MarketplaceRow = {
  scope: { scope: "global" },
  name: "their-name-for-it",
  repo: "https://github.com/VanillaGreenCom/kendex.git",
  repoKey: "vanillagreencom/kendex",
  repoIdentity: "github.com/vanillagreencom/kendex",
  path: null,
  resolvedPath: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  provenance: null,
  meta: null,
  mode: null,
  recordsUnreadable: false,
};

const OFFERED: AvailablePackage = {
  kind: "skill",
  name: "gh",
  description: null,
  summary: null,
  tags: [],
  bundles: [],
  dependencies: { required: [], optional: [] },
  state: "available",
  collision: null,
  updatedAt: null,
};

const SET: BundleDetail = {
  name: "gh",
  description: "a set that happens to share the package's name",
  version: null,
  category: null,
  members: [{ kind: "skill", name: "gh", state: "available" }],
  installedMembers: 0,
  totalMembers: 1,
  collision: null,
  recordsUnreadable: false,
};

/** The skill saved, recorded under a spelling of the marketplace that is
 *  not the one the subscription row carries. */
const SAVED_SKILL: SavedItem = {
  bookmark: {
    repo: "vanillagreencom/kendex",
    item: { is: "package", kind: "skill" },
    name: "gh",
  },
  repoIdentity: "github.com/vanillagreencom/kendex",
  catalog: CATALOG,
  reach: { at: "offered" },
};

/** A curated set saved from the same marketplace. */
const SAVED_SET: SavedItem = {
  ...SAVED_SKILL,
  bookmark: {
    repo: SAVED_SKILL.bookmark.repo,
    item: { is: "bundle" },
    name: "starter",
  },
};

const savedIs = (saved: SavedItem[]) => {
  vi.mocked(commands.bookmarksList).mockResolvedValue({
    status: "ok",
    data: saved,
  });
};

beforeEach(() => {
  vi.clearAllMocks();
  savedIs([]);
  vi.mocked(commands.bookmarkAdd).mockResolvedValue({
    status: "ok",
    data: SAVED_SKILL.bookmark,
  });
  vi.mocked(commands.bookmarkRemove).mockResolvedValue({
    status: "ok",
    data: null,
  });
  vi.mocked(commands.templatesList).mockResolvedValue({
    status: "ok",
    data: [],
  });
  vi.mocked(commands.templateCreateFromSelection).mockResolvedValue({
    status: "ok",
    data: { name: "Kit", id: "kit", members: [], customizations: {} },
  });
  useBookmarksStore.setState({
    saved: [],
    everRead: false,
    read: { status: "idle" },
    busy: false,
    refused: null,
  });
  useMarketplacesStore.setState({
    rows: [SUBSCRIPTION],
    summaries: {},
    bundles: {},
    readErrors: {},
    read: READ_LANDED,
  });
  useTemplatesStore.setState({
    templates: [],
    everRead: false,
    read: { status: "idle" },
    busy: false,
    refused: null,
  });
  useNavStore.setState({
    page: "marketplaces",
    libraryTab: "installed",
    availableRef: null,
    bundleRef: null,
    history: [],
    future: [],
  });
  useInstallFlow.setState({ ask: null, outcome: null, running: false });
});

/** The one control whose accessible name is exactly this. */
function control(host: HTMLElement | Document, label: string): HTMLElement {
  const found = host.querySelector<HTMLElement>(`[aria-label="${label}"]`);
  if (!found) throw new Error(`no control labelled ${label}`);
  return found;
}

/** The one button whose text is exactly this. */
function button(host: HTMLElement | Document, text: string): HTMLButtonElement {
  const found = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
    (one) => one.textContent?.trim() === text,
  );
  if (!found) throw new Error(`no button reading ${text}`);
  return found;
}

const table = () =>
  mount(
    <PackagesTable
      entries={[{ catalog: CATALOG, row: OFFERED, recordsUnreadable: false }]}
      showMarketplace={false}
    />,
  );

describe("the Bookmark control on a marketplace row", () => {
  it("saves the marketplace the subscription points at, not its alias", async () => {
    const host = table();
    await settle();

    await act(async () => control(host, bookmarkLabel("gh")).click());
    expect(commands.bookmarkAdd).toHaveBeenCalledWith({
      repo: SUBSCRIPTION.repo,
      item: { is: "package", kind: "skill" },
      name: "gh",
    });
  });

  it("does not open the row it sits in, by pointer or by Enter", async () => {
    const host = table();
    await settle();

    await act(async () => control(host, bookmarkLabel("gh")).click());
    expect(useNavStore.getState().page).toBe("marketplaces");
    expect(useNavStore.getState().availableRef).toBeNull();
    expect(useInstallFlow.getState().ask).toBeNull();

    // The keyboard reaches the control on its own focus stop, and Enter
    // pressed on it belongs to it rather than to the row behind it.
    const saved = control(host, bookmarkLabel("gh"));
    saved.focus();
    expect(document.activeElement).toBe(saved);
    await act(async () => {
      saved.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Enter", bubbles: true }),
      );
    });
    expect(useNavStore.getState().page).toBe("marketplaces");
    expect(useNavStore.getState().availableRef).toBeNull();
  });

  it("reads one saved item alike wherever it is drawn, and tells the item type apart", async () => {
    savedIs([SAVED_SKILL]);
    const rowHost = table();
    // A curated set of the same name in the same marketplace is a
    // different saved item, and reads as unsaved.
    const cardHost = mount(
      <BundleCards
        catalog={CATALOG}
        bundles={[SET]}
        error={undefined}
        places={new Map()}
      />,
    );
    await settle();

    // The row's marketplace is spelled one way and the bookmark records
    // another; both fold to one identity, so the row reads as saved.
    expect(control(rowHost, removeBookmarkLabel("gh"))).toBeTruthy();
    expect(control(cardHost, bookmarkLabel("gh"))).toBeTruthy();
  });

  it("is offered on a folder marketplace, and saves the directory the folder resolves to", async () => {
    const folder: MarketplaceRow = {
      ...SUBSCRIPTION,
      name: "catalog",
      repo: null,
      repoKey: null,
      // What core folds a folder declaration to: the directory it
      // resolves to, never the spelling.
      repoIdentity: "/home/me/catalog",
      path: "catalog",
      resolvedPath: "/home/me/catalog",
    };
    const catalog: Catalog = {
      by: "subscription",
      scope: { scope: "global" },
      source: "catalog",
    };
    useMarketplacesStore.setState({ rows: [folder] });
    const host = mount(
      <PackagesTable
        entries={[{ catalog, row: OFFERED, recordsUnreadable: false }]}
        showMarketplace={false}
      />,
    );
    await settle();

    await act(async () => control(host, bookmarkLabel("gh")).click());
    expect(commands.bookmarkAdd).toHaveBeenCalledWith({
      repo: "/home/me/catalog",
      item: { is: "package", kind: "skill" },
      name: "gh",
    });
  });

  it("claims nothing about what is saved over a read that failed, and reads again on the next mount", async () => {
    vi.mocked(commands.bookmarksList).mockResolvedValue({
      status: "error",
      error: "the index could not be read",
    });
    const failed = table();
    await settle();
    for (const label of [bookmarkLabel("gh"), removeBookmarkLabel("gh")]) {
      expect(failed.querySelector(`[aria-label="${label}"]`), label).toBeNull();
    }

    // The failure does not stand for the session: the next control to
    // mount reads again, and draws what that read answers.
    savedIs([SAVED_SKILL]);
    const again = table();
    await settle();
    expect(control(again, removeBookmarkLabel("gh"))).toBeTruthy();
  });

  it("forgets the saved item it is on, through the bookmark it holds", async () => {
    savedIs([SAVED_SKILL]);
    const host = table();
    await settle();

    await act(async () => control(host, removeBookmarkLabel("gh")).click());
    expect(commands.bookmarkRemove).toHaveBeenCalledWith(SAVED_SKILL.bookmark);
  });
});

describe("the Bookmarks tab", () => {
  it("says nothing is saved only once a read has answered", async () => {
    const host = mount(<BookmarksView />);
    expect(host.textContent).not.toContain(BOOKMARKS_EMPTY);
    await settle();
    expect(host.textContent).toContain(BOOKMARKS_EMPTY);
  });

  it("keeps its rows when a read fails, and says so when none ever landed", async () => {
    vi.mocked(commands.bookmarksList).mockResolvedValue({
      status: "error",
      error: "the index could not be read",
    });
    const host = mount(<BookmarksView />);
    await settle();
    expect(host.textContent).toContain(BOOKMARKS_UNREADABLE);
    expect(host.textContent).not.toContain(BOOKMARKS_EMPTY);
  });

  it("opens the marketplace page a row names, and Back returns to this tab", async () => {
    savedIs([SAVED_SKILL]);
    useNavStore.setState({ page: "library", libraryTab: "bookmarks" });
    const host = mount(<BookmarksView />);
    await settle();

    await act(async () => button(host, "gh").click());
    expect(useNavStore.getState().page).toBe("availablePackage");
    expect(useNavStore.getState().availableRef).toEqual({
      catalog: CATALOG,
      kind: "skill",
      name: "gh",
    });

    act(() => useNavStore.getState().back());
    expect(useNavStore.getState().page).toBe("library");
    expect(useNavStore.getState().libraryTab).toBe("bookmarks");
  });

  it("sends a saved row into the guided install, from the marketplace that offers it", async () => {
    savedIs([SAVED_SKILL]);
    const host = mount(<BookmarksView />);
    await settle();

    await act(async () => button(host, INSTALL_ACTION).click());
    const ask = useInstallFlow.getState().ask;
    expect(ask?.subjects[0]?.groups).toEqual([
      {
        source: "their-name-for-it",
        browsing: { scope: "global" },
        items: [{ kind: "skill", name: "gh" }],
        bundle: null,
      },
    ]);
    expect(ask?.subjects[0]?.kinds).toEqual(["skill"]);
  });

  it("installs two places' subscriptions sharing one alias as two requests", async () => {
    // An alias is unique inside one manifest only: the personal scope and
    // a project can each key a different marketplace under it.
    const project: Scope = { scope: "project", root: "/home/me/app" };
    savedIs([
      SAVED_SKILL,
      {
        bookmark: {
          repo: "other/skills",
          item: { is: "package", kind: "skill" },
          name: "lint",
        },
        repoIdentity: "github.com/other/skills",
        catalog: {
          by: "subscription",
          scope: project,
          source: "their-name-for-it",
        },
        reach: { at: "offered" },
      },
    ]);
    const host = mount(<BookmarksView />);
    await settle();

    await act(async () => control(host, "Select gh").click());
    await act(async () => control(host, "Select lint").click());
    await act(async () => button(host, installSelectedLabel(2)).click());
    expect(useInstallFlow.getState().ask?.subjects[0]?.groups).toEqual([
      {
        source: "their-name-for-it",
        browsing: { scope: "global" },
        items: [{ kind: "skill", name: "gh" }],
        bundle: null,
      },
      {
        source: "their-name-for-it",
        browsing: project,
        items: [{ kind: "skill", name: "lint" }],
        bundle: null,
      },
    ]);
  });

  it("says a ticked set installs every one of its members", async () => {
    vi.mocked(commands.marketplaceBundle).mockResolvedValue({
      status: "ok",
      data: {
        ...SET,
        name: "starter",
        members: [
          { kind: "skill", name: "gh", state: "available" },
          { kind: "skill", name: "lint", state: "available" },
          { kind: "agent", name: "reviewer", state: "available" },
        ],
        totalMembers: 3,
      },
    });
    vi.mocked(commands.installTargets).mockResolvedValue({
      status: "ok",
      data: [],
    });
    savedIs([SAVED_SKILL, SAVED_SET]);
    const host = mount(
      <>
        <BookmarksView />
        <InstallDialog />
      </>,
    );
    await settle();

    await act(async () => control(host, "Select gh").click());
    await act(async () => control(host, "Select starter").click());
    await act(async () => button(host, installSelectedLabel(2)).click());
    await settle();
    expect(commands.marketplaceBundle).toHaveBeenCalledWith(
      CATALOG,
      "starter",
      null,
    );
    expect(useInstallFlow.getState().ask?.subjects[0]?.count).toBe(4);
    expect(document.body.textContent).toContain(
      `${selectedLabel(2)} · ${packageCount(4)}`,
    );
  });

  it("opens no install on a set whose members cannot be read, and says why", async () => {
    vi.mocked(commands.marketplaceBundle).mockResolvedValue({
      status: "error",
      error: "no manifest there",
    });
    savedIs([SAVED_SET]);
    const host = mount(<BookmarksView />);
    await settle();

    await act(async () => button(host, INSTALL_ACTION).click());
    await settle();
    expect(useInstallFlow.getState().ask).toBeNull();
    expect(host.textContent).toContain("no manifest there");
  });

  it("offers a ticked selection to a template, as the marketplace the bookmark records", async () => {
    savedIs([SAVED_SKILL]);
    const host = mount(<BookmarksView />);
    await settle();

    await act(async () => control(host, "Select gh").click());
    expect(button(host, installSelectedLabel(1))).toBeTruthy();

    await act(async () => button(host, ADD_TO_TEMPLATE_LABEL).click());
    await settle();
    const name = document.querySelector<HTMLInputElement>("#template-new-name");
    if (!name) throw new Error("the new-template name field is not on screen");
    await userEvent.type(name, "Kit");
    await act(async () => button(document, "Save").click());
    expect(commands.templateCreateFromSelection).toHaveBeenCalledWith("Kit", [
      {
        kind: "skill",
        name: "gh",
        enabled: true,
        source: {
          held: "marketplace",
          repo: SAVED_SKILL.bookmark.repo,
          rev: null,
        },
      },
    ]);
  });

  it("keeps a row whose marketplace cannot be served, says why, and offers no install", async () => {
    savedIs([
      {
        ...SAVED_SKILL,
        catalog: null,
        reach: { at: "unavailable", why: "that folder is not there any more" },
      },
    ]);
    const host = mount(<BookmarksView />);
    await settle();

    expect(host.textContent).toContain("gh");
    expect(host.textContent).toContain("that folder is not there any more");
    expect(() => button(host, INSTALL_ACTION)).toThrow();
    // It can still be let go of, and it opens nothing.
    expect(control(host, removeBookmarkLabel("gh"))).toBeTruthy();
    expect(() => button(host, "gh")).toThrow();
  });
});
