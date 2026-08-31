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
  commands: { marketplacePackages: vi.fn() },
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
