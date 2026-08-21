import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useMarketplacesStore } from "./marketplaces";
import { catalogKey, marketKey, readErrorKey } from "./marketplaces-shared";

vi.mock("@/bindings", () => ({
  commands: { marketplaceSummary: vi.fn() },
}));
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), message: vi.fn(), error: vi.fn() },
}));

const repo = { by: "repo" as const, repo: "acme/kit" };
const key = catalogKey(repo);

describe("a repository's summary", () => {
  beforeEach(() => {
    useMarketplacesStore.setState({ summaries: {}, readErrors: {} });
  });

  it("fails under its own key so the packages table is not hidden", async () => {
    useMarketplacesStore.setState({ readErrors: { [key]: "packages broke" } });
    vi.mocked(commands.marketplaceSummary).mockResolvedValue({
      status: "error",
      error: "could not reach github.com",
    });

    await useMarketplacesStore.getState().loadSummary(repo);

    const errors = useMarketplacesStore.getState().readErrors;
    expect(errors[readErrorKey(key, "summary")]).toBe(
      "could not reach github.com",
    );
    expect(errors[key]).toBe("packages broke");
  });

  it("names the subscription the page carries on as", async () => {
    const scope = { scope: "project" as const, root: "/work/acme" };
    vi.mocked(commands.marketplaceSummary).mockResolvedValue({
      status: "ok",
      data: {
        provenance: "acme/kit",
        repoKey: "acme/kit",
        commit: null,
        meta: null,
        mode: "discovered",
        counts: {},
        warning: null,
        subscription: { scope, source: "kit" },
      },
    });

    await useMarketplacesStore.getState().loadSummary(repo);

    const held = useMarketplacesStore.getState().summaries[key]?.subscription;
    if (!held) throw new Error("no subscription was held");
    // What useCatalog derives from it addresses the subscription's own
    // cache, so rows a subscribed page already loaded are found.
    expect(
      catalogKey({
        by: "subscription",
        scope: held.scope,
        source: held.source,
      }),
    ).toBe(marketKey(scope, "kit"));
  });
});
