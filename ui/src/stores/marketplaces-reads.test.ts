import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useMarketplacesStore } from "./marketplaces";
import {
  catalogKey,
  dropCatalogCaches,
  readErrorKey,
  subscription,
} from "./marketplaces-shared";

vi.mock("@/bindings", () => ({
  commands: { marketplacePackages: vi.fn(), marketplaceBundles: vi.fn() },
}));
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), message: vi.fn(), error: vi.fn() },
}));
vi.mock("./preinstall-safety", () => ({ resetPreinstallSafety: vi.fn() }));

const catalog = subscription({ scope: "global" }, "kendex");
const key = catalogKey(catalog);
const offered = (name: string) => [
  {
    kind: "skill" as const,
    name,
    description: null,
    summary: null,
    tags: [],
    bundles: [],
    dependencies: { required: [], optional: [] },
    state: "available" as const,
    collision: null,
    updatedAt: null,
  },
];

const declared = (name: string) => [
  {
    name,
    description: null,
    version: null,
    category: null,
    members: [],
    installedMembers: 0,
    totalMembers: 0,
    collision: null,
    recordsUnreadable: false,
  },
];

const reads = [
  {
    name: "packages",
    field: "packages",
    errorRead: "packages",
    command: commands.marketplacePackages,
    load: () => useMarketplacesStore.getState().loadPackages(catalog),
    data: offered,
  },
  {
    name: "curated sets",
    field: "catalogBundles",
    errorRead: "bundles",
    command: commands.marketplaceBundles,
    load: () => useMarketplacesStore.getState().loadCatalogBundles(catalog),
    data: declared,
  },
] as const;

beforeEach(() => {
  useMarketplacesStore.setState({
    packages: {},
    catalogBundles: {},
    readErrors: {},
  });
  vi.mocked(commands.marketplacePackages).mockReset();
  vi.mocked(commands.marketplaceBundles).mockReset();
});

describe("catalog read settlement", () => {
  it("leaves a rejected read's reason under its own key", async () => {
    expect(reads.length).toBeGreaterThan(0);
    for (const row of reads) {
      vi.mocked(row.command).mockRejectedValue(new Error("the bridge is gone"));
      await expect(row.load(), row.name).resolves.toBeUndefined();
      const state = useMarketplacesStore.getState();
      expect(
        {
          error: state.readErrors[readErrorKey(key, row.errorRead)],
          value: state[row.field][key],
        },
        row.name,
      ).toEqual({ error: "the bridge is gone", value: undefined });
    }
  });

  it("rereads a slot whose answer outlived a cache drop", async () => {
    expect(reads.length).toBeGreaterThan(0);
    for (const row of reads) {
      let settleOld: (value: unknown) => void = () => {};
      vi.mocked(row.command)
        .mockImplementationOnce(
          () =>
            new Promise((resolve) => {
              settleOld = resolve;
            }) as never,
        )
        .mockResolvedValueOnce({
          status: "ok",
          data: row.data("after-refresh"),
        } as never);
      const pending = row.load();
      dropCatalogCaches((partial) => useMarketplacesStore.setState(partial));
      settleOld({ status: "ok", data: row.data("old-checkout") });
      await pending;
      expect(
        {
          calls: vi.mocked(row.command).mock.calls.length,
          name: useMarketplacesStore.getState()[row.field][key]?.[0]?.name,
        },
        row.name,
      ).toEqual({ calls: 2, name: "after-refresh" });
    }
  });

  it("shares outstanding reads per key and generation, including stale retries", async () => {
    const catalogs = [
      catalog,
      subscription({ scope: "project", root: "/fixture" }, "kendex"),
      subscription({ scope: "project", root: "/fixture" }, "agents"),
      subscription({ scope: "project", root: "/fixture" }, "agent-skills"),
    ];
    const lands: ((value: unknown) => void)[] = [];
    vi.mocked(commands.marketplacePackages).mockImplementation(
      () =>
        new Promise((resolve) => {
          lands.push(resolve as never);
        }),
    );
    const load = (one: typeof catalog) =>
      useMarketplacesStore.getState().loadPackages(one);
    const old = catalogs.flatMap((one) => [load(one), load(one), load(one)]);
    expect(commands.marketplacePackages).toHaveBeenCalledTimes(4);
    dropCatalogCaches((partial) => useMarketplacesStore.setState(partial));
    const current = catalogs.flatMap((one) => [load(one), load(one)]);
    expect(commands.marketplacePackages).toHaveBeenCalledTimes(8);
    // New generation lands before the old one. Old landings must not ask
    // again just because the current promise has left the in-flight map.
    for (const land of lands.slice(4))
      land({ status: "ok", data: offered("current") });
    await Promise.all(current);
    for (const land of lands.slice(0, 4))
      land({ status: "ok", data: offered("old") });
    await Promise.all(old);
    expect(commands.marketplacePackages).toHaveBeenCalledTimes(8);
    expect(
      catalogs.map(
        (one) =>
          useMarketplacesStore.getState().packages[catalogKey(one)][0].name,
      ),
    ).toEqual(["current", "current", "current", "current"]);
  });

  it("joins a current read still in flight when an old failure lands", async () => {
    for (const row of reads) {
      const lands: ((value: unknown) => void)[] = [];
      vi.mocked(row.command).mockImplementation(
        () =>
          new Promise((resolve) => {
            lands.push(resolve as never);
          }) as never,
      );
      const old = row.load();
      dropCatalogCaches((partial) => useMarketplacesStore.setState(partial));
      const current = row.load();
      lands[0]({ status: "error", error: "old failure" });
      await Promise.resolve();
      lands[1]({ status: "ok", data: row.data("current") });
      await Promise.all([old, current]);
      expect(vi.mocked(row.command).mock.calls.length, row.name).toBe(2);
      expect(
        useMarketplacesStore.getState().readErrors[
          readErrorKey(key, row.errorRead)
        ],
        row.name,
      ).toBeUndefined();
    }
  });

  it("allows an explicit retry after a coalesced failed read", async () => {
    for (const row of reads) {
      vi.mocked(row.command)
        .mockResolvedValueOnce({
          status: "error",
          error: "failed read",
        } as never)
        .mockResolvedValueOnce({
          status: "ok",
          data: row.data("retry"),
        } as never);
      await Promise.all([row.load(), row.load()]);
      expect(vi.mocked(row.command).mock.calls.length, row.name).toBe(1);
      expect(
        useMarketplacesStore.getState().readErrors[
          readErrorKey(key, row.errorRead)
        ],
        row.name,
      ).toBe("failed read");
      await row.load();
      expect(vi.mocked(row.command).mock.calls.length, row.name).toBe(2);
      expect(
        useMarketplacesStore.getState().readErrors[
          readErrorKey(key, row.errorRead)
        ],
        row.name,
      ).toBeUndefined();
    }
  });

  it("empties the catalog's curated sets on a cache drop", () => {
    useMarketplacesStore.setState({
      catalogBundles: { [key]: declared("before-refresh") },
    });
    dropCatalogCaches((partial) => useMarketplacesStore.setState(partial));
    expect(useMarketplacesStore.getState().catalogBundles).toEqual({});
  });
});
