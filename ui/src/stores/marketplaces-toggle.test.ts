// A bare repository page's action and what toggling its holder does to
// the summaries that decide which subscription the page carries on as.
import { toast } from "sonner";
import { describe, expect, it, vi } from "vitest";
import { commands, type MarketplaceRow } from "@/bindings";
import { READ_LANDED, READ_PENDING, readFailed } from "@/lib/read-state";
import { useMarketplacesStore } from "./marketplaces";
import { catalogKey, declaredHolder, repoAction } from "./marketplaces-shared";

vi.mock("@/bindings", () => ({
  commands: {
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
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
  // What core's source_ref::repo_identity answers for a GitHub reference.
  repoIdentity: repoKey ? `github.com/${repoKey}` : repo,
  provenance: repo,
  path: null,
  resolvedPath: null,
  rev: null,
  commit: null,
  enabled: true,
  counts: null,
  meta: null,
  mode: null,
  recordsUnreadable: false,
});

// There is no client-side "these rows are not current" refusal: the action
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
    expect(useMarketplacesStore.getState().summaries.kept).toEqual({
      provenance: "acme/kit",
    });
  });
});

describe("a bare repository page's action", () => {
  it("offers Turn on, not Subscribe, once its subscription is turned off", async () => {
    // Turning the held subscription off: the summary re-reads as bare, and
    // the live list is what says a (disabled) subscription still holds it.
    vi.mocked(commands.sourceToggle).mockResolvedValue({
      status: "ok",
      data: { sources: [] },
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
      "github.com/acme/kit",
    );
    expect(held?.enabled).toBe(false);
    expect(held?.name).toBe("kit");
  });

  // Turning a source off drops the packages it carried, so the toggle can
  // run a departing package's uninstaller — and the window has to say so.
  it("relays a toggle's removal report when a package left", async () => {
    const rows = [
      {
        name: "uninstaller ran",
        enabled: false,
        undone: [
          "commit-guards: running scripts/install-git-hooks --uninstall",
        ],
        calls: [
          ["commit-guards: running scripts/install-git-hooks --uninstall"],
        ],
      },
      {
        name: "no armed package left",
        enabled: true,
        undone: undefined,
        calls: [],
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const entry of rows) {
      vi.mocked(toast.message).mockClear();
      vi.mocked(commands.sourceToggle).mockResolvedValue({
        status: "ok",
        data: {
          sources: [],
          ...(entry.undone === undefined ? {} : { undone: entry.undone }),
        },
      });
      vi.mocked(commands.marketplacesOverview).mockResolvedValue({
        status: "ok",
        data: [],
      });
      await useMarketplacesStore
        .getState()
        .toggle({ scope: "global" }, "kit", entry.enabled);
      expect(vi.mocked(toast.message).mock.calls, entry.name).toEqual(
        entry.calls,
      );
    }
  });

  it("selects the action from the known identity and subscription read", () => {
    const disabled = { ...row("acme/kit", "acme/kit"), enabled: false };
    const gitlab = "https://gitlab.com/acme/kit";
    const declared = row(gitlab, null);
    const table = [
      {
        name: "identity pending",
        rows: [disabled],
        read: READ_PENDING,
        identity: null,
        kind: "checking",
      },
      {
        name: "disabled identity known",
        rows: [disabled],
        read: READ_LANDED,
        identity: "github.com/acme/kit",
        kind: "turn-on",
      },
      {
        name: "identity never arrived",
        rows: [disabled],
        read: READ_LANDED,
        identity: null,
        kind: "subscribe",
      },
      {
        name: "non-GitHub enabled",
        rows: [declared],
        read: READ_LANDED,
        identity: gitlab,
        kind: "refresh",
      },
      {
        name: "non-GitHub disabled",
        rows: [{ ...declared, enabled: false }],
        read: READ_LANDED,
        identity: gitlab,
        kind: "turn-on",
      },
      {
        name: "non-GitHub undeclared",
        rows: [declared],
        read: READ_LANDED,
        identity: "https://gitlab.com/acme/other",
        kind: "subscribe",
      },
      {
        name: "first overview pending",
        rows: [],
        read: READ_PENDING,
        identity: "github.com/acme/kit",
        kind: "checking",
      },
      {
        name: "overview confirmed empty",
        rows: [],
        read: READ_LANDED,
        identity: "github.com/acme/kit",
        kind: "subscribe",
      },
      {
        name: "first overview failed",
        rows: [],
        read: readFailed("offline"),
        identity: "github.com/acme/kit",
        kind: "checking",
      },
      {
        name: "failed overview kept rows",
        rows: [row("acme/kit", "acme/kit")],
        read: readFailed("offline"),
        identity: "github.com/acme/kit",
        kind: "refresh",
      },
    ];
    expect(table.length).toBeGreaterThan(0);
    for (const entry of table)
      expect(
        repoAction(entry.rows, entry.read, entry.identity).kind,
        entry.name,
      ).toBe(entry.kind);
  });

  it("offers Subscribe only when nothing declares the repository", () => {
    expect(
      declaredHolder([row("acme/kit", "acme/kit")], "github.com/other/repo"),
    ).toBeNull();
    const enabled = row("acme/kit", "acme/kit");
    const disabled = { ...enabled, name: "old", enabled: false };
    expect(
      declaredHolder([disabled, enabled], "github.com/acme/kit")?.name,
    ).toBe("kit");
  });
});

describe("a repository page carried on as a subscription", () => {
  it("invalidates summaries when a holder changes, regardless of spelling", async () => {
    const scope = { scope: "global" as const };
    const summary = {
      provenance: "acme/kit",
      repoKey: "acme/kit",
      repoIdentity: "github.com/acme/kit",
      commit: null,
      meta: null,
      mode: "discovered" as const,
      counts: {},
      warning: null,
    };
    const repoKey = catalogKey({ by: "repo", repo: "Acme/Kit" });
    const otherKey = catalogKey({ by: "repo", repo: "other/repo" });
    const lowerKey = catalogKey({ by: "repo", repo: "acme/kit" });
    const entries = [
      {
        name: "all summaries",
        rows: [row("acme/kit", "acme/kit")],
        summaries: {
          [repoKey]: { ...summary, subscription: { scope, source: "kit" } },
          [otherKey]: {
            ...summary,
            provenance: "other/repo",
            repoKey: "other/repo",
            repoIdentity: "github.com/other/repo",
            subscription: { scope, source: "other" },
          },
        },
        enabled: false,
        refreshed: [],
      },
      {
        name: "alternate declaration spelling",
        rows: [row("git@github.com:acme/kit.git", "acme/kit")],
        summaries: {
          [lowerKey]: {
            ...summary,
            provenance: "git@github.com:acme/kit.git",
            subscription: { scope, source: "kit" },
          },
        },
        enabled: false,
        refreshed: [],
      },
      {
        name: "holder turned back on",
        rows: [{ ...row("acme/kit", "acme/kit"), enabled: false }],
        summaries: { [repoKey]: { ...summary, subscription: null } },
        enabled: true,
        refreshed: [row("acme/kit", "acme/kit")],
      },
    ];
    expect(entries.length).toBeGreaterThan(0);
    for (const entry of entries) {
      useMarketplacesStore.setState({
        rows: entry.rows,
        summaries: entry.summaries,
      });
      vi.mocked(commands.sourceToggle).mockResolvedValue({
        status: "ok",
        data: { sources: [] },
      });
      vi.mocked(commands.marketplacesOverview).mockResolvedValue({
        status: "ok",
        data: entry.refreshed,
      });
      await useMarketplacesStore.getState().toggle(scope, "kit", entry.enabled);
      expect(useMarketplacesStore.getState().summaries, entry.name).toEqual({});
    }
  });
});
