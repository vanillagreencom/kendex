// @vitest-environment jsdom
// The Bundles tab's read is wiring, not a prop: the page has to ask for the
// catalog's declared sets and put what comes back on screen. Prop-driven
// tests of the cards cannot see that the ask was made at all.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { BundleDetail } from "@/bindings";
import { commands } from "@/bindings";
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
  it("asks for the catalog's declared sets and shows them in the Bundles tab", async () => {
    const host = mount(<MarketplaceDetailPage />);
    await settle();

    expect(commands.marketplaceBundles).toHaveBeenCalledWith(catalog);
    expect(host.textContent).toContain("starter");
    expect(host.textContent).toContain("the six things to begin with");
    expect(host.textContent).not.toContain("doesn't offer curated sets");
  });

  it("shows the read's own error when the catalog's sets cannot be read", async () => {
    vi.mocked(commands.marketplaceBundles).mockResolvedValue({
      status: "error",
      error: "the catalog is unreadable",
    });

    const host = mount(<MarketplaceDetailPage />);
    await settle();

    expect(host.textContent).toContain("the catalog is unreadable");
    expect(host.textContent).not.toContain("doesn't offer curated sets");
  });
});
