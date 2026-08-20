// A bare repository page's action and what toggling its holder does to
// the summaries that decide which subscription the page carries on as.
import { describe, expect, it, vi } from "vitest";
import { commands, type MarketplaceRow } from "@/bindings";
import { useMarketplacesStore } from "./marketplaces";
import { declaredHolder, repoAction } from "./marketplaces-shared";

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

describe("a bare repository page's action", () => {
  it("stays neutral, not Subscribe, while the live list cannot be trusted", async () => {
    useMarketplacesStore.setState({ rows: [], rowsCurrent: true });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "error",
      error: "settings file is malformed",
    });
    await useMarketplacesStore.getState().load();

    const state = useMarketplacesStore.getState();
    expect(repoAction(state.rows, state.rowsCurrent, "acme/kit").kind).toBe(
      "checking",
    );
    expect(repoAction([], true, "acme/kit").kind).toBe("subscribe");
  });

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
