import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type MarketplaceRow } from "@/bindings";
import { useMarketplacesStore } from "./marketplaces";

vi.mock("@/bindings", () => ({
  commands: {
    marketplacesOverview: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), message: vi.fn(), error: vi.fn() },
}));

const kept: MarketplaceRow = {
  scope: { scope: "global" },
  name: "kit",
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  path: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
};

// A failed overview read keeps the rows it had — the page does not blank —
// but `rowsCurrent` comes down and `loaded` comes up: the read answered
// that it couldn't, which is not the same news as one still on its way.
describe("the marketplaces overview read failing", () => {
  beforeEach(() => {
    useMarketplacesStore.setState({
      rows: [kept],
      loaded: true,
      rowsCurrent: true,
      error: null,
    });
    vi.clearAllMocks();
  });

  it("keeps the rows and marks them not current on a returned refusal", async () => {
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "error",
      error: "offline",
    });

    await useMarketplacesStore.getState().load();

    const state = useMarketplacesStore.getState();
    expect(state.rows).toEqual([kept]);
    expect(state.rowsCurrent).toBe(false);
    expect(state.loaded).toBe(true);
    expect(state.error).toBe("offline");
  });

  // A rejected call used to escape the store entirely: rowsCurrent stayed
  // true and the tile kept counting rows nobody could confirm.
  it("lands a rejected call the same as a returned refusal", async () => {
    vi.mocked(commands.marketplacesOverview).mockRejectedValue(
      new Error("ipc down"),
    );

    await useMarketplacesStore.getState().load();

    const state = useMarketplacesStore.getState();
    expect(state.rows).toEqual([kept]);
    expect(state.rowsCurrent).toBe(false);
    expect(state.loaded).toBe(true);
    expect(state.error).toBe("ipc down");
  });
});
