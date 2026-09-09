// @vitest-environment jsdom
// The Bundles tab's read is wiring, not a prop: the page has to ask for the
// catalog's declared sets and put what comes back on screen. Prop-driven
// tests of the cards cannot see that the ask was made at all.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { BundleDetail } from "@/bindings";
import { commands } from "@/bindings";
import { MARKETPLACE_PLACES_TITLE } from "@/lib/copy-marketplaces";
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
    },
    {
      name: "shows the read's own error when the catalog's sets cannot be read",
      response: { status: "error", error: "the catalog is unreadable" },
      shown: ["the catalog is unreadable"],
    },
  ] satisfies {
    name: string;
    response: Awaited<ReturnType<typeof commands.marketplaceBundles>>;
    shown: string[];
  }[];
  expect(rows).toHaveLength(2);
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
      },
      row.name,
    ).toEqual({
      request: [catalog],
      shown: row.shown.map(() => true),
      empty: false,
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
