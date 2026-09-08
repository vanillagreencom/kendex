import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type MarketplaceRow } from "@/bindings";
import { READ_LANDED } from "@/lib/read-state";
import { useMarketplacesStore } from "./marketplaces";

vi.mock("@/bindings", () => ({
  commands: {
    marketplacesOverview: vi.fn(),
    marketplaceSubscribe: vi.fn(),
    // Subscribing writes its report through `repo_effects`, so
    // `lib/rescan.ts` reads the machine again behind it whatever it
    // answered. Nothing here is about what those reads find; unmocked they
    // reject out of a promise nobody awaits.
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    libraryProvenance: vi.fn(),
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
  repoIdentity: "github.com/acme/kit",
  provenance: null,
  path: null,
  resolvedPath: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
  recordsUnreadable: false,
};

// A failed overview read keeps the rows it had — the page does not blank —
// and the read state says `failed`: the read answered that it couldn't,
// which is not the same news as one still on its way.
describe("the marketplaces overview read failing", () => {
  beforeEach(() => {
    useMarketplacesStore.setState({
      rows: [kept],
      read: READ_LANDED,
      error: null,
    });
    vi.clearAllMocks();
  });

  it("keeps the rows and marks them not current when the overview fails", async () => {
    const rows = [
      { name: "returned refusal", rejected: false, reason: "offline" },
      { name: "rejected bridge call", rejected: true, reason: "ipc down" },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      useMarketplacesStore.setState({
        rows: [kept],
        read: READ_LANDED,
        error: null,
      });
      if (row.rejected)
        vi.mocked(commands.marketplacesOverview).mockRejectedValue(
          new Error(row.reason),
        );
      else
        vi.mocked(commands.marketplacesOverview).mockResolvedValue({
          status: "error",
          error: row.reason,
        });
      await useMarketplacesStore.getState().load();
      const state = useMarketplacesStore.getState();
      expect(
        {
          rows: state.rows,
          status: state.read.status,
          error: state.error,
          readError: state.read.error,
        },
        row.name,
      ).toEqual({
        rows: [kept],
        status: "failed",
        error: row.reason,
        readError: row.reason,
      });
    }
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
    expect(state.read.error).toBe("offline");
    expect(state.read.status).toBe("failed");
  });

  it("clears the stale-read reason once a read answers again", async () => {
    vi.mocked(commands.marketplacesOverview).mockResolvedValueOnce({
      status: "error",
      error: "offline",
    });
    await useMarketplacesStore.getState().load();
    expect(useMarketplacesStore.getState().read.error).toBe("offline");

    vi.mocked(commands.marketplacesOverview).mockResolvedValueOnce({
      status: "ok",
      data: [kept],
    });
    await useMarketplacesStore.getState().load();
    expect(useMarketplacesStore.getState().read.error).toBeNull();
  });

  // Home's mount-time load overlaps the page's own, a retry button against
  // either, and every mutation re-reading behind them. Without ordering a
  // slow early one landing last stamps its stale rows current and clears
  // the notice saying they are not.
  it("discards an older overview result after a fresher answer", async () => {
    const rows = [
      { name: "older successful read", rejected: false },
      { name: "older rejected read", rejected: true },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      let resolveFirst!: (
        value: Awaited<ReturnType<typeof commands.marketplacesOverview>>,
      ) => void;
      let rejectFirst!: (reason: Error) => void;
      vi.mocked(commands.marketplacesOverview).mockReturnValueOnce(
        new Promise((resolve, reject) => {
          resolveFirst = resolve;
          rejectFirst = reject;
        }),
      );
      const first = useMarketplacesStore.getState().load();
      const fresh = [{ ...kept, name: row.rejected ? "kit" : "fresh" }];
      vi.mocked(commands.marketplacesOverview).mockResolvedValue({
        status: "ok",
        data: fresh,
      });
      await useMarketplacesStore.getState().load();
      if (row.rejected) rejectFirst(new Error("ipc down"));
      else resolveFirst({ status: "ok", data: [{ ...kept, name: "stale" }] });
      await first;
      const state = useMarketplacesStore.getState();
      expect(
        {
          rows: state.rows,
          status: state.read.status,
          error: state.read.error,
        },
        row.name,
      ).toEqual({ rows: fresh, status: "landed", error: null });
    }
  });
});
