// A bare repository page's action and what toggling its holder does to
// the summaries that decide which subscription the page carries on as.
import { describe, expect, it, vi } from "vitest";
import { commands, type MarketplaceRow } from "@/bindings";
import { READ_LANDED, READ_PENDING, readFailed } from "@/lib/read-state";
import { useMarketplacesStore } from "./marketplaces";
import { catalogKey, declaredHolder, repoAction } from "./marketplaces-shared";

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

// The client-side "these rows are not current" refusal is gone: the action
// goes out and the engine is the judge. That trade only holds if a refusal
// is honoured here — a toggle that reported failure and dropped every
// catalog cache anyway would leave the pages re-reading behind a write that
// never happened.
describe("a toggle the engine refuses", () => {
  it("says why, and changes nothing behind it", async () => {
    const { toast } = await import("sonner");
    useMarketplacesStore.setState({
      rows: [row("acme/kit", "acme/kit")],
      summaries: { kept: { provenance: "acme/kit" } as never },
    });
    vi.mocked(commands.sourceToggle).mockResolvedValue({
      status: "error",
      error: "the settings file is read-only",
    });

    await useMarketplacesStore
      .getState()
      .toggle({ scope: "global" }, "kit", false);

    expect(toast.error).toHaveBeenCalledWith("the settings file is read-only");
    // Nothing committed, so nothing downstream re-reads: the caches stand
    // and the overview is not asked again.
    expect(commands.marketplacesOverview).not.toHaveBeenCalled();
    expect(useMarketplacesStore.getState().summaries.kept).toBeDefined();
  });
});

describe("a bare repository page's action", () => {
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

  it("stays neutral until the canonical key is known, then matches by it", () => {
    const disabled = { ...row("acme/kit", "acme/kit"), enabled: false };
    // The page was opened as "Acme/Kit": before the summary or the directory
    // row supplies the canonical key, no spelling is compared.
    expect(repoAction([disabled], READ_LANDED, null).kind).toBe("checking");
    expect(repoAction([disabled], READ_LANDED, "acme/kit").kind).toBe(
      "turn-on",
    );
  });

  // Before the first read answers there are no rows to look in, so every
  // repository would look undeclared and Subscribe would be offered over
  // one this machine already holds — which the engine then refuses as a
  // duplicate, with the person having pressed a button for nothing.
  it("stays neutral while the first read of the list is still out", () => {
    expect(repoAction([], READ_PENDING, "acme/kit").kind).toBe("checking");
    expect(repoAction([], READ_LANDED, "acme/kit").kind).toBe("subscribe");
  });

  // A FIRST read that failed leaves no rows at all, so every repository
  // looks undeclared. Offering Subscribe there is the guess the engine
  // then refuses as a duplicate, with the person having pressed a button
  // for nothing.
  it("stays neutral when the first read failed and left no rows", () => {
    expect(repoAction([], readFailed("offline"), "acme/kit").kind).toBe(
      "checking",
    );
  });

  // A read that failed is not the same: the rows it kept are what this
  // machine last knew, and the engine refuses anything they were wrong
  // about. Holding the page neutral there would leave no way back.
  it("acts on rows a failed read left, rather than going neutral", () => {
    const declared = row("acme/kit", "acme/kit");
    expect(repoAction([declared], readFailed("offline"), "acme/kit").kind).toBe(
      "refresh",
    );
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

describe("a repository page carried on as a subscription", () => {
  it("re-asks every summary when a subscription is toggled", async () => {
    const repoKey = catalogKey({ by: "repo", repo: "Acme/Kit" });
    const otherKey = catalogKey({ by: "repo", repo: "other/repo" });
    const summary = {
      provenance: "acme/kit",
      repoKey: "acme/kit",
      commit: null,
      meta: null,
      mode: "discovered" as const,
      counts: {},
      warning: null,
    };
    useMarketplacesStore.setState({
      rows: [row("acme/kit", "acme/kit")],
      summaries: {
        [repoKey]: {
          ...summary,
          subscription: { scope: { scope: "global" }, source: "kit" },
        },
        [otherKey]: {
          ...summary,
          provenance: "other/repo",
          repoKey: "other/repo",
          subscription: { scope: { scope: "global" }, source: "other" },
        },
      },
    });
    vi.mocked(commands.sourceToggle).mockResolvedValue({
      status: "ok",
      data: [],
    });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [],
    });

    await useMarketplacesStore
      .getState()
      .toggle({ scope: "global" }, "kit", false);

    const summaries = useMarketplacesStore.getState().summaries;
    expect(summaries[repoKey]).toBeUndefined();
    expect(summaries[otherKey]).toBeUndefined();
  });

  it("re-asks a summary whose holder spells the repository another way", async () => {
    const repoKey = catalogKey({ by: "repo", repo: "acme/kit" });
    useMarketplacesStore.setState({
      rows: [row("git@github.com:acme/kit.git", "acme/kit")],
      summaries: {
        [repoKey]: {
          // Carried on as the subscription: provenance is its declaration.
          provenance: "git@github.com:acme/kit.git",
          repoKey: "acme/kit",
          commit: null,
          meta: null,
          mode: "discovered",
          counts: {},
          warning: null,
          subscription: { scope: { scope: "global" }, source: "kit" },
        },
      },
    });
    vi.mocked(commands.sourceToggle).mockResolvedValue({
      status: "ok",
      data: [],
    });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [],
    });

    await useMarketplacesStore
      .getState()
      .toggle({ scope: "global" }, "kit", false);

    expect(useMarketplacesStore.getState().summaries[repoKey]).toBeUndefined();
  });

  it("re-asks again when the holder is turned back on", async () => {
    const repoKey = catalogKey({ by: "repo", repo: "Acme/Kit" });
    // Turned off earlier: the summary reloaded bare, carried by nothing.
    useMarketplacesStore.setState({
      rows: [{ ...row("acme/kit", "acme/kit"), enabled: false }],
      summaries: {
        [repoKey]: {
          provenance: "acme/kit",
          repoKey: "acme/kit",
          commit: null,
          meta: null,
          mode: "discovered",
          counts: {},
          warning: null,
          subscription: null,
        },
      },
    });
    vi.mocked(commands.sourceToggle).mockResolvedValue({
      status: "ok",
      data: [],
    });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [row("acme/kit", "acme/kit")],
    });

    await useMarketplacesStore
      .getState()
      .toggle({ scope: "global" }, "kit", true);

    expect(useMarketplacesStore.getState().summaries[repoKey]).toBeUndefined();
  });
});
