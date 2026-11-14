import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  commands,
  type DirectoryRow,
  type ItemWarning,
  type MarketplaceRow,
} from "@/bindings";
import { UNKNOWN_COMPLETION_STEP } from "@/lib/copy";
import {
  keptNotInstalledTitle,
  keptRecordedStep,
  unsubscribeUnknownTitle,
} from "@/lib/copy-marketplaces";
import { READ_LANDED, READ_PENDING } from "@/lib/read-state";
import { useMarketplacesStore } from "./marketplaces";
import { rowSubscribed, subscribedKeys } from "./marketplaces-shared";
import { useProblemsStore } from "./problems";

vi.mock("@/bindings", () => ({
  commands: {
    updatesOverview: vi.fn().mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    }),
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

const listed: DirectoryRow = {
  repo: "Acme/Kit",
  repoKey: "acme/kit",
  repoIdentity: "github.com/acme/kit",
  name: "kit",
  description: null,
  tags: [],
  featured: false,
  packageCount: 1,
  bundleCount: 0,
  // The directory's snapshot, fetched before anyone subscribed.
  subscribed: false,
  packages: [],
  bundles: [],
};

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

/** A link the keep held as written, with its fix: the keep's own report. */
const kept: ItemWarning = {
  kind: "skill",
  name: "house-style",
  message:
    "SKILL.md links to ../../memory/x.md, which may no longer reach its file",
  remediation: "Use an absolute path.",
  detail: "skill-link-kept: SKILL.md: ../../memory/x.md",
};
// The line `sayWritten` gives a warning, which the person reads with its fix
// beneath it.
const keptToast = `${kept.name}: ${kept.message}`;

describe("a Community row's Subscribed marker", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useMarketplacesStore.setState({
      rows: [],
      read: READ_PENDING,
      summaries: {},
    });
  });

  it("flips as soon as a subscribe lands, however the repo was spelled", async () => {
    vi.mocked(commands.marketplaceSubscribe).mockResolvedValue({
      status: "ok",
      data: {
        name: "kit",
        reference: "https://github.com/Acme/Kit.git",
        rev: null,
        lead: null,
        notes: [],
      },
    });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [row("https://github.com/Acme/Kit.git", "acme/kit")],
    });
    expect(
      subscribedKeys(useMarketplacesStore.getState().rows).has(
        "github.com/acme/kit",
      ),
    ).toBe(false);

    // Subscribe answers with the alias it declared, so a caller that goes
    // on to install from it has the name; a refusal answers the words.
    const outcome = await useMarketplacesStore
      .getState()
      .subscribe({ scope: "global" }, "https://github.com/Acme/Kit.git", null);

    expect(outcome).toEqual({ name: "kit" });
    const held = subscribedKeys(useMarketplacesStore.getState().rows);
    expect(held.has(listed.repoIdentity)).toBe(true);
  });

  // The set holds identities, not GitHub keys: a GitLab subscription has
  // no `repoKey`, and a set built from keys would read it as no
  // subscription — a card never marked Subscribed for it, and a Subscribe
  // offered that the engine refuses as a duplicate.
  it("marks a non-GitHub row Subscribed from its identity", () => {
    const gitlab = "https://gitlab.com/acme/kit";
    const live = subscribedKeys([row(gitlab, null)]);
    expect(
      rowSubscribed({ repoIdentity: gitlab, subscribed: false }, live),
    ).toBe(true);
    expect(
      rowSubscribed(
        { repoIdentity: "https://gitlab.com/acme/other", subscribed: true },
        live,
      ),
    ).toBe(false);
  });

  // A subscribe plans the whole scope, so its plan can take a package away
  // as well as bring one — a rendering the engine refuses drops that
  // package whatever the planning options say. What its uninstaller ran is
  // the subscribe's own account to give.
  it("relays a subscribe's removal report when a package left", async () => {
    const rows = [
      {
        name: "uninstaller ran",
        undone: ["guards: running scripts/arm --uninstall"],
        calls: [["guards: running scripts/arm --uninstall"]],
      },
      { name: "no armed package left", undone: undefined, calls: [] },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const entry of rows) {
      vi.mocked(toast.message).mockClear();
      vi.mocked(commands.marketplaceSubscribe).mockResolvedValue({
        status: "ok",
        data: {
          name: "kit",
          reference: "https://github.com/Acme/Kit.git",
          rev: null,
          lead: null,
          notes: [],
          ...(entry.undone === undefined ? {} : { undone: entry.undone }),
        },
      });
      vi.mocked(commands.marketplacesOverview).mockResolvedValue({
        status: "ok",
        data: [],
      });
      await useMarketplacesStore
        .getState()
        .subscribe(
          { scope: "global" },
          "https://github.com/Acme/Kit.git",
          null,
        );
      expect(vi.mocked(toast.message).mock.calls, entry.name).toEqual(
        entry.calls,
      );
    }
  });

  it("ignores path subscriptions, which are no repository", () => {
    // A folder carries an identity too: the directory it resolves to.
    const folder: MarketplaceRow = {
      ...row("", null),
      repo: null,
      path: "catalog",
      resolvedPath: "/home/me/catalog",
      repoIdentity: "/home/me/catalog",
    };
    expect(subscribedKeys([folder]).size).toBe(0);
  });

  // There is no client-side "these rows are not current" refusal: the
  // action goes out and the engine is the judge. That trade only holds if
  // the refusal is honoured here — an unsubscribe that reported failure
  // and then dropped the caches, reloaded and toasted success would tell
  // the person a subscription went that is still there.
  // The words travel with the answer rather than through the shared slot:
  // `load` empties that slot on every landing read, so a dialog reading
  // the refusal back out of it is left open by a read arriving in the gap,
  // with an empty error area and no account of why nothing happened.
  it("hands back a refusal a concurrent read would have erased", async () => {
    useMarketplacesStore.setState({ rows: [], read: READ_LANDED });
    vi.mocked(commands.marketplaceUnsubscribe).mockResolvedValue({
      status: "error",
      error: { phase: "refused", message: "an edited package is in the way" },
    });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [],
    });

    const outcome = await useMarketplacesStore
      .getState()
      .unsubscribe({ scope: "global" }, "kit", "Acme Kit", false, false);
    await useMarketplacesStore.getState().load();

    expect(useMarketplacesStore.getState().error).toBeNull();
    expect(outcome).toEqual({ error: "an edited package is in the way" });
  });

  it("honours a refused unsubscribe rather than claiming it landed", async () => {
    const { toast } = await import("sonner");
    useMarketplacesStore.setState({
      rows: [row("Acme/Kit", "acme/kit")],
      read: READ_LANDED,
      summaries: { kept: { provenance: "acme/kit" } as never },
    });
    vi.mocked(commands.marketplaceUnsubscribe).mockResolvedValue({
      status: "error",
      error: { phase: "refused", message: "an edited package is in the way" },
    });

    const ok = await useMarketplacesStore
      .getState()
      .unsubscribe({ scope: "global" }, "kit", "Acme Kit", false, false);

    // The refusal comes back from the call — the dialog reads it there, not
    // out of the shared slot, which every landing read clears.
    expect(ok).toEqual({ error: "an edited package is in the way" });
    expect(toast.success).not.toHaveBeenCalled();
    // Nothing committed, so the rows and the caches stand.
    expect(commands.marketplacesOverview).not.toHaveBeenCalled();
    expect(useMarketplacesStore.getState().summaries.kept).toEqual({
      provenance: "acme/kit",
    });
    expect(useMarketplacesStore.getState().rows).toEqual([
      row("Acme/Kit", "acme/kit"),
    ]);
  });

  it("clears once an unsubscribe lands, whatever the directory snapshot said", async () => {
    useMarketplacesStore.setState({
      rows: [row("Acme/Kit", "acme/kit")],
      read: READ_LANDED,
    });
    vi.mocked(commands.marketplaceUnsubscribe).mockResolvedValue({
      status: "ok",
      data: { warnings: [] },
    });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "ok",
      data: [],
    });

    const ok = await useMarketplacesStore
      .getState()
      .unsubscribe({ scope: "global" }, "kit", "Acme Kit", false, false);

    expect(ok).toEqual({ done: true });
    const live = subscribedKeys(useMarketplacesStore.getState().rows);
    // The snapshot still says subscribed; the live list outranks it.
    expect(rowSubscribed({ ...listed, subscribed: true }, live)).toBe(false);
  });

  // Rust produces removal reports and detach warnings; the window must present both.
  it("relays an unsubscribe's removal reports and capture warnings", async () => {
    const rows = [
      {
        name: "uninstaller ran",
        keep: false,
        warnings: [],
        undone: [
          "commit-guards: running scripts/install-git-hooks --uninstall",
        ],
        calls: [
          ["commit-guards: running scripts/install-git-hooks --uninstall"],
        ],
      },
      {
        name: "no armed package left",
        keep: false,
        warnings: [],
        undone: undefined,
        calls: [],
      },
      {
        name: "the keep kept a link as written",
        keep: true,
        warnings: [kept],
        undone: undefined,
        calls: [[keptToast, { description: kept.remediation }]],
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const entry of rows) {
      vi.mocked(toast.message).mockClear();
      useMarketplacesStore.setState({
        rows: [row("Acme/Kit", "acme/kit")],
        read: READ_LANDED,
      });
      vi.mocked(commands.marketplaceUnsubscribe).mockResolvedValue({
        status: "ok",
        data: {
          warnings: entry.warnings,
          ...(entry.undone === undefined ? {} : { undone: entry.undone }),
        },
      });
      vi.mocked(commands.marketplacesOverview).mockResolvedValue({
        status: "ok",
        data: [],
      });
      await useMarketplacesStore
        .getState()
        .unsubscribe({ scope: "global" }, "kit", "Acme Kit", entry.keep, false);
      expect(vi.mocked(toast.message).mock.calls, entry.name).toEqual(
        entry.calls,
      );
    }
  });

  // Either the write landed with a step behind it failing, or nothing says
  // whether it ran: the keep's install failed after the keep, or the call
  // failed on its way and the transport folded it into a bare string. Neither
  // is a refusal, so the dialog closes, the error dialog says the stop once,
  // what a recorded keep reported still reaches the window, and the rows are
  // read again.
  it("closes on an unsubscribe that may have landed and says what stopped", async () => {
    const rows = [
      {
        name: "a recorded keep",
        error: {
          phase: "recorded" as const,
          message: "the render of skill gh failed",
          written: [kept],
        },
        title: keptNotInstalledTitle,
        steps: [keptRecordedStep("kit")],
        message: "the render of skill gh failed",
        calls: [[keptToast, { description: kept.remediation }]],
      },
      {
        name: "a call that never answered",
        error: "connection reset",
        title: unsubscribeUnknownTitle,
        steps: [UNKNOWN_COMPLETION_STEP],
        message: "connection reset",
        calls: [],
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const entry of rows) {
      useProblemsStore.getState().closeError();
      vi.mocked(toast.message).mockClear();
      vi.mocked(toast.success).mockClear();
      vi.mocked(commands.marketplacesOverview).mockClear();
      useMarketplacesStore.setState({
        rows: [row("Acme/Kit", "acme/kit")],
        read: READ_LANDED,
        error: null,
      });
      vi.mocked(commands.marketplaceUnsubscribe).mockResolvedValue({
        status: "error",
        error: entry.error,
      });
      vi.mocked(commands.marketplacesOverview).mockResolvedValue({
        status: "ok",
        data: [],
      });

      const outcome = await useMarketplacesStore
        .getState()
        .unsubscribe({ scope: "global" }, "kit", "Acme Kit", true, false);

      expect(outcome, entry.name).toEqual({ done: true });
      expect(useMarketplacesStore.getState().error, entry.name).toBeNull();
      const dialog = useProblemsStore.getState().dialog;
      expect(dialog.open, entry.name).toBe(true);
      // Titled by the name the page shows, never the alias the engine is
      // sent: the two differ here.
      expect(dialog.title, entry.name).toBe(entry.title("Acme Kit"));
      expect(dialog.title, entry.name).not.toBe(entry.title("kit"));
      expect(dialog.message, entry.name).toBe(entry.message);
      expect(dialog.steps, entry.name).toEqual(entry.steps);
      expect(vi.mocked(toast.message).mock.calls, entry.name).toEqual(
        entry.calls,
      );
      expect(toast.success, entry.name).not.toHaveBeenCalled();
      expect(commands.marketplacesOverview, entry.name).toHaveBeenCalled();
      expect(useMarketplacesStore.getState().rows, entry.name).toEqual([]);
    }
  });

  it("falls back to the snapshot only before the live list has loaded", () => {
    expect(rowSubscribed({ ...listed, subscribed: true }, null)).toBe(true);
  });

  it("keeps the directory snapshot when the live overview cannot be read", async () => {
    useMarketplacesStore.setState({ rows: [], read: READ_LANDED });
    vi.mocked(commands.marketplacesOverview).mockResolvedValue({
      status: "error",
      error: "settings file is malformed",
    });

    await useMarketplacesStore.getState().load();

    const state = useMarketplacesStore.getState();
    expect(state.read.status).toBe("failed");
    const live =
      state.read.status === "landed" ? subscribedKeys(state.rows) : null;
    expect(rowSubscribed({ ...listed, subscribed: true }, live)).toBe(true);
  });
});
