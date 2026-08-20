import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type DirectoryRow, type MarketplaceRow } from "@/bindings";
import { useMarketplacesStore } from "./marketplaces";
import {
  catalogKey,
  declaredHolder,
  rowSubscribed,
  subscribedKeys,
} from "./marketplaces-shared";

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
    useMarketplacesStore.setState({
      rows: [],
      rowsCurrent: false,
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

  it("keeps the directory snapshot when the live overview cannot be read", async () => {
    useMarketplacesStore.setState({ rows: [], rowsCurrent: true });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "error",
      error: "settings file is malformed",
    });

    await useMarketplacesStore.getState().load();

    const state = useMarketplacesStore.getState();
    expect(state.rowsCurrent).toBe(false);
    const live = state.rowsCurrent ? subscribedKeys(state.rows) : null;
    expect(rowSubscribed({ ...listed, subscribed: true }, live)).toBe(true);
  });
});

describe("a repository page carried on as a subscription", () => {
  it("re-asks which subscription to carry on as when that one is toggled", async () => {
    const repoKey = catalogKey({ by: "repo", repo: "Acme/Kit" });
    const otherKey = catalogKey({ by: "repo", repo: "other/repo" });
    const summary = {
      provenance: "acme/kit",
      commit: null,
      meta: null,
      mode: "discovered" as const,
      counts: {},
      warning: null,
    };
    useMarketplacesStore.setState({
      summaries: {
        [repoKey]: {
          ...summary,
          subscription: { scope: { scope: "global" }, source: "kit" },
        },
        [otherKey]: {
          ...summary,
          subscription: { scope: { scope: "global" }, source: "other" },
        },
      },
    });
    vi.mocked(commands.sourceToggle).mockResolvedValue({
      status: "ok",
      data: [],
    });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [],
    });

    await useMarketplacesStore
      .getState()
      .toggle({ scope: "global" }, "kit", false);

    const summaries = useMarketplacesStore.getState().summaries;
    expect(summaries[repoKey]).toBeUndefined();
    expect(summaries[otherKey]).toBeDefined();
  });
});

describe("a bare repository page's action", () => {
  it("offers Turn on, not Subscribe, once its subscription is turned off", async () => {
    // Turning the held subscription off: the summary re-reads as bare, and
    // the live list is what says a (disabled) subscription still holds it.
    vi.mocked(commands.sourceToggle).mockResolvedValue({
      status: "ok",
      data: [],
    });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [{ ...row("acme/kit", "acme/kit"), enabled: false }],
    });
    await useMarketplacesStore
      .getState()
      .toggle({ scope: "global" }, "kit", false);

    const held = declaredHolder(
      useMarketplacesStore.getState().rows,
      "acme/kit",
    );
    expect(held?.enabled).toBe(false);
    expect(held?.name).toBe("kit");
  });

  it("offers Subscribe only when nothing declares the repository", () => {
    expect(
      declaredHolder([row("acme/kit", "acme/kit")], "other/repo"),
    ).toBeNull();
    const enabled = row("acme/kit", "acme/kit");
    const disabled = { ...enabled, name: "old", enabled: false };
    expect(declaredHolder([disabled, enabled], "acme/kit")?.name).toBe("kit");
  });
});
