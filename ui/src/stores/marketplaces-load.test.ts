import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type MarketplaceRow } from "@/bindings";
import { useMarketplacesStore } from "./marketplaces";

vi.mock("@/bindings", () => ({
  commands: {
    marketplacesOverview: vi.fn(),
    marketplaceSubscribe: vi.fn(),
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
      checkError: null,
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
    expect(state.checkError).toBe("offline");
  });

  // Actions write the shared error field too; only load() may write the
  // reason the stale-read notices show, or a failed subscribe would
  // rewrite it while the rows stay stale for the original reason.
  it("a subscribe refusal does not change the stale-read notice", async () => {
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "error",
      error: "offline",
    });
    await useMarketplacesStore.getState().load();

    vi.mocked(commands.marketplaceSubscribe).mockResolvedValue({
      status: "error",
      error: "bad repo",
    });
    await useMarketplacesStore
      .getState()
      .subscribe({ scope: "global" }, "acme/kit", null);

    const state = useMarketplacesStore.getState();
    expect(state.error).toBe("bad repo");
    expect(state.checkError).toBe("offline");
    expect(state.rowsCurrent).toBe(false);
  });

  it("clears the stale-read reason once a read answers again", async () => {
    vi.mocked(commands.marketplacesOverview).mockResolvedValueOnce({
      status: "error",
      error: "offline",
    });
    await useMarketplacesStore.getState().load();
    expect(useMarketplacesStore.getState().checkError).toBe("offline");

    vi.mocked(commands.marketplacesOverview).mockResolvedValueOnce({
      status: "ok",
      data: [kept],
    });
    await useMarketplacesStore.getState().load();
    expect(useMarketplacesStore.getState().checkError).toBeNull();
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

  // Home's mount-time load overlaps the page's own reads; without ordering
  // a slow early one landing last would stamp its stale rows current.
  it("discards a slow load that lands after a fresher one", async () => {
    let resolveFirst!: (
      value: Awaited<ReturnType<typeof commands.marketplacesOverview>>,
    ) => void;
    vi.mocked(commands.marketplacesOverview).mockReturnValueOnce(
      new Promise((resolve) => {
        resolveFirst = resolve;
      }),
    );
    const first = useMarketplacesStore.getState().load();

    const fresh = [{ ...kept, name: "fresh" }];
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: fresh,
    });
    await useMarketplacesStore.getState().load();

    resolveFirst({ status: "ok", data: [{ ...kept, name: "stale" }] });
    await first;

    const state = useMarketplacesStore.getState();
    expect(state.rows).toEqual(fresh);
    expect(state.rowsCurrent).toBe(true);
  });

  it("discards a slow failed load landing after a fresher answer", async () => {
    let rejectFirst!: (reason: Error) => void;
    vi.mocked(commands.marketplacesOverview).mockReturnValueOnce(
      new Promise((_, reject) => {
        rejectFirst = reject;
      }),
    );
    const first = useMarketplacesStore.getState().load();

    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [kept],
    });
    await useMarketplacesStore.getState().load();

    rejectFirst(new Error("ipc down"));
    await first;

    const state = useMarketplacesStore.getState();
    expect(state.rowsCurrent).toBe(true);
    expect(state.error).toBeNull();
  });
});
