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

  it("empties the catalog's curated sets on a cache drop", () => {
    useMarketplacesStore.setState({
      catalogBundles: { [key]: declared("before-refresh") },
    });
    dropCatalogCaches((partial) => useMarketplacesStore.setState(partial));
    expect(useMarketplacesStore.getState().catalogBundles).toEqual({});
  });
});
