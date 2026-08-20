import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type DirectoryRow, type MarketplaceRow } from "@/bindings";
import { useMarketplacesStore } from "./marketplaces";
import { rowSubscribed, subscribedKeys } from "./marketplaces-shared";

vi.mock("@/bindings", () => ({
  commands: {
    marketplaceSubscribe: vi.fn(),
    marketplaceUnsubscribe: vi.fn(),
    marketplacesOverview: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), message: vi.fn(), error: vi.fn() },
}));
vi.mock("./audit", () => ({
  useAuditStore: { getState: () => ({ refresh: vi.fn() }) },
}));
vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));

const listed: DirectoryRow = {
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  name: "kit",
  description: null,
  tags: [],
  featured: false,
  packageCount: 1,
  bundleCount: 0,
  // The directory's snapshot, fetched before anyone subscribed.
  subscribed: false,
  packages: [],
  bundles: [],
};

const row = (repo: string, repoKey: string | null): MarketplaceRow => ({
  scope: { scope: "global" },
  name: "kit",
  repo,
  repoKey,
  path: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
});

describe("a Community row's Subscribed marker", () => {
  beforeEach(() => {
    useMarketplacesStore.setState({ rows: [] });
  });

  it("flips as soon as a subscribe lands, however the repo was spelled", async () => {
    vi.mocked(commands.marketplaceSubscribe).mockResolvedValue({
      status: "ok",
      data: {
        name: "kit",
        reference: "https://github.com/Acme/Kit.git",
        rev: null,
        lead: null,
        notes: [],
      },
    });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [row("https://github.com/Acme/Kit.git", "acme/kit")],
    });
    expect(
      subscribedKeys(useMarketplacesStore.getState().rows).has("acme/kit"),
    ).toBe(false);

    const ok = await useMarketplacesStore
      .getState()
      .subscribe({ scope: "global" }, "https://github.com/Acme/Kit.git", null);

    expect(ok).toBe(true);
    const held = subscribedKeys(useMarketplacesStore.getState().rows);
    expect(listed.repoKey !== null && held.has(listed.repoKey)).toBe(true);
  });

  it("ignores path subscriptions, which are no repository", () => {
    expect(subscribedKeys([row("", null)]).size).toBe(0);
  });

  it("clears once an unsubscribe lands, whatever the directory snapshot said", async () => {
    useMarketplacesStore.setState({
      rows: [row("Acme/Kit", "acme/kit")],
      loaded: true,
    });
    vi.mocked(commands.marketplaceUnsubscribe).mockResolvedValue({
      status: "ok",
      data: null,
    });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [],
    });

    const ok = await useMarketplacesStore
      .getState()
      .unsubscribe({ scope: "global" }, "kit", false, false);

    expect(ok).toBe(true);
    const live = subscribedKeys(useMarketplacesStore.getState().rows);
    // The snapshot still says subscribed; the live list outranks it.
    expect(rowSubscribed({ ...listed, subscribed: true }, live)).toBe(false);
  });

  it("falls back to the snapshot only before the live list has loaded", () => {
    expect(rowSubscribed({ ...listed, subscribed: true }, null)).toBe(true);
  });
});
