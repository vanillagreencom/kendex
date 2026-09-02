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
  },
];

// The loaders are called with `void` from effects, so a rejection that
// escapes is one nothing catches: no answer under the key, no reason under
// the error key, and a page that goes on loading with nothing to retry
// from. It lands as this read's own failure instead.
describe("a catalog read the bridge could not make", () => {
  beforeEach(() => {
    useMarketplacesStore.setState({ packages: {}, readErrors: {} });
    vi.mocked(commands.marketplacePackages).mockReset();
  });

  it("leaves the reason under its own key rather than throwing", async () => {
    vi.mocked(commands.marketplacePackages).mockRejectedValue(
      new Error("the bridge is gone"),
    );

    await expect(
      useMarketplacesStore.getState().loadPackages(catalog),
    ).resolves.toBeUndefined();

    const state = useMarketplacesStore.getState();
    expect(state.readErrors[readErrorKey(key, "packages")]).toBe(
      "the bridge is gone",
    );
    expect(state.packages[key]).toBeUndefined();
  });
});

describe("a read that outlives a cache drop", () => {
  beforeEach(() => {
    useMarketplacesStore.setState({ packages: {}, readErrors: {} });
    vi.mocked(commands.marketplacePackages).mockReset();
  });

  it("is not stored, and the slot is read again", async () => {
    let settleOld: (value: unknown) => void = () => {};
    vi.mocked(commands.marketplacePackages)
      .mockImplementationOnce(
        () => new Promise((resolve) => (settleOld = resolve)) as never,
      )
      .mockResolvedValueOnce({ status: "ok", data: offered("after-refresh") });

    const pending = useMarketplacesStore.getState().loadPackages(catalog);
    // Check for updates lands while the read is still in flight.
    dropCatalogCaches((partial) => useMarketplacesStore.setState(partial));
    settleOld({ status: "ok", data: offered("old-checkout") });
    await pending;

    expect(commands.marketplacePackages).toHaveBeenCalledTimes(2);
    expect(useMarketplacesStore.getState().packages[key]?.[0]?.name).toBe(
      "after-refresh",
    );
  });
});

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

// The page reads the reason under readErrorKey(catalogKey, "bundles"). The
// store has to fail under that same key, or a failed read renders the
// pending line for the life of the session with no way to retry.
describe("a curated-sets read the bridge could not make", () => {
  beforeEach(() => {
    useMarketplacesStore.setState({ catalogBundles: {}, readErrors: {} });
    vi.mocked(commands.marketplaceBundles).mockReset();
  });

  it("leaves the reason under the key the page subscribes to", async () => {
    vi.mocked(commands.marketplaceBundles).mockRejectedValue(
      new Error("the bridge is gone"),
    );

    await expect(
      useMarketplacesStore.getState().loadCatalogBundles(catalog),
    ).resolves.toBeUndefined();

    const state = useMarketplacesStore.getState();
    expect(state.readErrors[readErrorKey(key, "bundles")]).toBe(
      "the bridge is gone",
    );
    expect(state.catalogBundles[key]).toBeUndefined();
  });
});

// A check-for-updates or a changed source can change which sets a catalog
// declares, so the list goes with every other derived cache. Left behind, it
// would show one marketplace's sets under another.
describe("the catalog's curated sets across a cache drop", () => {
  beforeEach(() => {
    useMarketplacesStore.setState({ catalogBundles: {}, readErrors: {} });
    vi.mocked(commands.marketplaceBundles).mockReset();
  });

  it("is emptied by the drop", () => {
    useMarketplacesStore.setState({
      catalogBundles: { [key]: declared("before-refresh") },
    });

    dropCatalogCaches((partial) => useMarketplacesStore.setState(partial));

    expect(useMarketplacesStore.getState().catalogBundles).toEqual({});
  });

  it("does not store a read that outlived the drop, and asks again", async () => {
    let settleOld: (value: unknown) => void = () => {};
    vi.mocked(commands.marketplaceBundles)
      .mockImplementationOnce(
        () => new Promise((resolve) => (settleOld = resolve)) as never,
      )
      .mockResolvedValueOnce({
        status: "ok",
        data: declared("after-refresh"),
      });

    const pending = useMarketplacesStore.getState().loadCatalogBundles(catalog);
    dropCatalogCaches((partial) => useMarketplacesStore.setState(partial));
    settleOld({ status: "ok", data: declared("old-checkout") });
    await pending;

    expect(commands.marketplaceBundles).toHaveBeenCalledTimes(2);
    expect(useMarketplacesStore.getState().catalogBundles[key]?.[0]?.name).toBe(
      "after-refresh",
    );
  });
});
