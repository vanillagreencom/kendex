import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type DirectoryRow, type MarketplaceRow } from "@/bindings";
import { READ_LANDED, READ_PENDING } from "@/lib/read-state";
import { useMarketplacesStore } from "./marketplaces";
import { rowSubscribed, subscribedKeys } from "./marketplaces-shared";

vi.mock("@/bindings", () => ({
  commands: {
    marketplaceSubscribe: vi.fn(),
    marketplaceUnsubscribe: vi.fn(),
    marketplacesOverview: vi.fn(),
    sourceToggle: vi.fn(),
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
    vi.clearAllMocks();
    useMarketplacesStore.setState({
      rows: [],
      read: READ_PENDING,
      summaries: {},
    });
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

  // The client-side "these rows are not current" refusal is gone: the
  // action goes out and the engine is the judge. That trade only holds if
  // the refusal is honoured here — an unsubscribe that reported failure
  // and then dropped the caches, reloaded and toasted success would tell
  // the person a subscription went that is still there.
  it("honours a refused unsubscribe rather than claiming it landed", async () => {
    const { toast } = await import("sonner");
    useMarketplacesStore.setState({
      rows: [row("Acme/Kit", "acme/kit")],
      read: READ_LANDED,
      summaries: { kept: { provenance: "acme/kit" } as never },
    });
    vi.mocked(commands.marketplaceUnsubscribe).mockResolvedValue({
      status: "error",
      error: "an edited package is in the way",
    });

    const ok = await useMarketplacesStore
      .getState()
      .unsubscribe({ scope: "global" }, "kit", false, false);

    expect(ok).toBe(false);
    expect(useMarketplacesStore.getState().error).toBe(
      "an edited package is in the way",
    );
    expect(toast.success).not.toHaveBeenCalled();
    // Nothing committed, so the rows and the caches stand.
    expect(commands.marketplacesOverview).not.toHaveBeenCalled();
    expect(useMarketplacesStore.getState().summaries.kept).toBeDefined();
    expect(useMarketplacesStore.getState().rows).toHaveLength(1);
  });

  it("clears once an unsubscribe lands, whatever the directory snapshot said", async () => {
    useMarketplacesStore.setState({
      rows: [row("Acme/Kit", "acme/kit")],
      read: READ_LANDED,
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

  it("keeps the directory snapshot when the live overview cannot be read", async () => {
    useMarketplacesStore.setState({ rows: [], read: READ_LANDED });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "error",
      error: "settings file is malformed",
    });

    await useMarketplacesStore.getState().load();

    const state = useMarketplacesStore.getState();
    expect(state.read.status).toBe("failed");
    const live =
      state.read.status === "landed" ? subscribedKeys(state.rows) : null;
    expect(rowSubscribed({ ...listed, subscribed: true }, live)).toBe(true);
  });
});
