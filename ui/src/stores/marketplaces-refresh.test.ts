// A refresh can make a subscription readable that was not; every open
// repository page then re-asks which subscription to carry on as.
import { describe, expect, it, vi } from "vitest";
import { commands, type MarketplaceRow } from "@/bindings";
import { useMarketplacesStore } from "./marketplaces";
import { catalogKey } from "./marketplaces-shared";

vi.mock("@/bindings", () => ({
  commands: {
    marketplaceSubscribe: vi.fn(),
    marketplaceUnsubscribe: vi.fn(),
    marketplaceSummary: vi.fn(),
    marketplacesOverview: vi.fn(),
    sourcesRefresh: vi.fn(),
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

describe("a repository page whose holder could not be read", () => {
  it("carries on as the holder once Check for updates made it readable", async () => {
    const repoKey = catalogKey({ by: "repo", repo: "acme/kit" });
    const bare = {
      provenance: "acme/kit",
      repoKey: "acme/kit",
      commit: null,
      meta: null,
      mode: "discovered" as const,
      counts: {},
      warning: null,
      subscription: null,
    };
    useMarketplacesStore.setState({
      rows: [row("git@github.com:acme/kit.git", "acme/kit")],
      summaries: { [repoKey]: bare },
    });
    vi.mocked(commands.sourcesRefresh).mockResolvedValue({
      status: "ok",
      data: [],
    });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [row("git@github.com:acme/kit.git", "acme/kit")],
    });
    vi.mocked(commands.marketplaceSummary).mockResolvedValue({
      status: "ok",
      data: {
        ...bare,
        subscription: { scope: { scope: "global" }, source: "kit" },
      },
    });

    await useMarketplacesStore.getState().checkForUpdates();
    await vi.waitFor(() => {
      expect(
        useMarketplacesStore.getState().summaries[repoKey]?.subscription
          ?.source,
      ).toBe("kit");
    });
    expect(commands.marketplaceSummary).toHaveBeenCalledWith({
      by: "repo",
      repo: "acme/kit",
    });
  });
});
