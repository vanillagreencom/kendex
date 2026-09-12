// @vitest-environment jsdom
// The Bundles tab's read is wiring, not a prop: the page has to ask for the
// catalog's declared sets and put what comes back on screen. Prop-driven
// tests of the cards cannot see that the ask was made at all.
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { BundleDetail } from "@/bindings";
import { commands } from "@/bindings";
import {
  MARKETPLACE_NOT_DOWNLOADED,
  MARKETPLACE_OFFERS_NO_PACKAGES,
  MARKETPLACE_PLACES_TITLE,
  MARKETPLACE_READING_PACKAGES,
} from "@/lib/copy-marketplaces";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { subscription } from "@/stores/marketplaces-shared";
import { useNavStore } from "@/stores/nav";
import { mount, settle } from "@/test/dom";
import { MarketplaceDetailPage } from "./marketplace-detail";

vi.mock("@/bindings", () => ({
  commands: {
    marketplacesOverview: vi.fn(),
    marketplacePackages: vi.fn(),
    marketplaceBundles: vi.fn(),
    // The page reads the provenance join once, to say which projects hold
    // each package and each set.
    libraryProvenance: vi.fn(),
    // The Bookmark control every marketplace surface now carries reads
    // the saved list once on mount.
    bookmarksList: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const catalog = subscription({ scope: "global" }, "kit");

const starter: BundleDetail = {
  name: "starter",
  description: "the six things to begin with",
  version: null,
  category: null,
  members: [{ kind: "skill", name: "gh", state: "available" }],
  installedMembers: 0,
  totalMembers: 1,
  collision: null,
  recordsUnreadable: false,
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.marketplacesOverview).mockResolvedValue({
    status: "ok",
    data: [],
  });
  vi.mocked(commands.marketplacePackages).mockResolvedValue({
    status: "ok",
    data: [],
  });
  vi.mocked(commands.marketplaceBundles).mockResolvedValue({
    status: "ok",
    data: [starter],
  });
  vi.mocked(commands.libraryProvenance).mockResolvedValue({
    status: "ok",
    data: [],
  });
  useMarketplacesStore.setState({
    rows: [],
    packages: {},
    bundles: {},
    catalogBundles: {},
    summaries: {},
    readErrors: {},
  });
  useNavStore.setState({ marketplaceRef: catalog });
});

describe("opening a marketplace", () => {
  const rows = [
    {
      name: "asks for the catalog's declared sets and shows them in the Bundles tab",
      response: { status: "ok", data: [starter] },
      shown: ["starter", "the six things to begin with"],
      alert: false,
    },
    {
      name: "shows the read's own error when the catalog's sets cannot be read",
      response: { status: "error", error: "the catalog is unreadable" },
      shown: ["the catalog is unreadable"],
      alert: true,
    },
    // The store keeps the refusal's shape, so the page can tell a
    // subscription nothing has downloaded yet from a read that went wrong.
    {
      name: "says a never-downloaded marketplace is that, not a read failure",
      response: {
        status: "error",
        error: { kind: "source-pending", source: "kit" },
      },
      shown: [MARKETPLACE_NOT_DOWNLOADED],
      alert: false,
    },
  ] satisfies {
    name: string;
    response: Awaited<ReturnType<typeof commands.marketplaceBundles>>;
    shown: string[];
    alert: boolean;
  }[];
  expect(rows).toHaveLength(3);
  it.each(rows)("$name", async (row) => {
    useMarketplacesStore.setState({ catalogBundles: {}, readErrors: {} });
    vi.mocked(commands.marketplaceBundles).mockResolvedValue(row.response);
    const host = mount(<MarketplaceDetailPage />);
    await settle();
    expect(
      {
        request: vi.mocked(commands.marketplaceBundles).mock.lastCall,
        shown: row.shown.map((value) => host.textContent?.includes(value)),
        empty: host.textContent?.includes("doesn't offer curated sets"),
        alert: host.querySelector('[role="alert"]') !== null,
      },
      row.name,
    ).toEqual({
      request: [catalog],
      shown: row.shown.map(() => true),
      empty: false,
      alert: row.alert,
    });
  });
});

// A marketplace page is about the marketplace. A tab of projects on it
// invited the reader to manage a place from a page that manages none, and
// which projects hold what it offers is now said on the packages and the
// sets themselves, with the source's own details on About.
describe("the marketplace page's tabs", () => {
  it("offers its sets, its packages and its details, and no projects tab", async () => {
    useMarketplacesStore.setState({
      rows: [
        {
          scope: { scope: "global" },
          name: "kit",
          repo: "Acme/Kit",
          repoKey: "acme/kit",
          repoIdentity: "github.com/acme/kit",
          provenance: "Acme/Kit",
          path: null,
          resolvedPath: null,
          rev: null,
          commit: null,
          enabled: true,
          counts: null,
          meta: null,
          mode: null,
          recordsUnreadable: false,
        },
      ],
    });
    const host = mount(<MarketplaceDetailPage />);
    await settle();

    const tabs = [...host.querySelectorAll('[role="tab"]')].map(
      (tab) => tab.textContent ?? "",
    );
    expect(tabs).toEqual(["Bundles", "Packages", "About"]);
    expect(tabs).not.toContain(MARKETPLACE_PLACES_TITLE);
  });
});

// An empty slot is not an empty catalog. `offered` is `cached ?? NONE`, so
// the row count cannot tell a read still out from one that landed with
// nothing; only the cache slot's presence can, which is what the branch
// keys on.
describe("the Packages tab's read states", () => {
  const openPackages = async (host: HTMLElement) => {
    const tab = [...host.querySelectorAll('[role="tab"]')].find(
      (node) => node.textContent === "Packages",
    );
    await userEvent.click(tab as HTMLElement);
    await settle();
  };

  const rows = [
    {
      name: "says it is reading while the packages read is still out",
      response: new Promise<never>(() => {}),
      shown: MARKETPLACE_READING_PACKAGES,
      absent: MARKETPLACE_OFFERS_NO_PACKAGES,
    },
    {
      name: "says the catalog offers none once that read has landed empty",
      response: Promise.resolve({ status: "ok" as const, data: [] }),
      shown: MARKETPLACE_OFFERS_NO_PACKAGES,
      absent: MARKETPLACE_READING_PACKAGES,
    },
  ];
  expect(rows).toHaveLength(2);
  it.each(rows)("$name", async (row) => {
    useMarketplacesStore.setState({ packages: {}, readErrors: {} });
    vi.mocked(commands.marketplacePackages).mockReturnValue(
      row.response as ReturnType<typeof commands.marketplacePackages>,
    );
    const host = mount(<MarketplaceDetailPage />);
    await settle();
    await openPackages(host);
    expect(
      {
        shown: host.textContent?.includes(row.shown),
        absent: host.textContent?.includes(row.absent),
      },
      row.name,
    ).toEqual({ shown: true, absent: false });
  });
});
