import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { useProblemsStore } from "./problems";
import { useUpdatesStore } from "./updates";

vi.mock("@/bindings", () => ({
  commands: {
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    updateSetIgnored: vi.fn(),
    packageSetRev: vi.fn(),
    packageUpdate: vi.fn(),
    applyDiscardEdits: vi.fn(),
    packageFork: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

function row(overrides: Partial<UpdateRow>): UpdateRow {
  return {
    scope: { scope: "global" },
    kind: "skill",
    name: "gh",
    source: "vstack",
    repo: "owner/catalog",
    repoIdentity: "owner/catalog",
    current: { commit: "a".repeat(40), label: "v1", date: null },
    latest: { commit: "b".repeat(40), label: "v2", date: null },
    updateAvailable: true,
    pinned: false,
    ignored: false,
    blockedByLocalEdit: false,
    editedHarnesses: [],
    forkableHarness: null,
    canDiscard: true,
    canTakeLatest: true,
    holdOwner: null,
    derived: false,
    forked: false,
    mixed: false,
    removedUpstream: false,
    ...overrides,
  };
}

describe("updates store: bulk update", () => {
  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: true });
    vi.clearAllMocks();
  });

  // A transport rejection escapes the apply sequence without recording a
  // failure — only the applier sees it, and the success toast must not
  // stand over it.
  it("claims no success when the transport fails mid-run", async () => {
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.packageUpdate).mockRejectedValue(new Error("ipc down"));
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [] },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await useUpdatesStore.getState().updateRows([row({})]);

    expect(toast.success).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe("ipc down");
  });

  it("a bulk update brings each place current on its own", async () => {
    const acme = { scope: "project", root: "/home/x/acme" } as const;
    const shop = { scope: "project", root: "/home/x/shop" } as const;
    const view = {
      scope: { scope: "global" } as const,
      drift: [],
      plan: [],
      notes: [],
      warnings: [],
      safety: [],
      adoptable: ADOPTABLE,
      exits: [],
    };
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "ok",
      data: view,
    });
    vi.mocked(commands.packageUpdate).mockResolvedValue({
      status: "ok",
      data: view,
    });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [] },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await useUpdatesStore.getState().updateRows([
      row({ name: "gh", scope: acme, pinned: true }),
      row({ name: "review", scope: acme }),
      row({ name: "gh" }),
      row({
        name: "gh",
        scope: shop,
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    ]);

    expect(commands.packageSetRev).toHaveBeenCalledTimes(1);
    expect(commands.packageSetRev).toHaveBeenCalledWith(
      acme,
      "skill",
      "gh",
      "b".repeat(40),
    );
    // Every following place gets its own package-scoped apply — moving
    // gh's hold in acme leaves review's follower there untouched.
    expect(vi.mocked(commands.packageUpdate).mock.calls).toEqual([
      [acme, "skill", "review"],
      [{ scope: "global" }, "skill", "gh"],
    ]);
    expect(toast.success).toHaveBeenCalledWith(
      "Updated 2 packages — 1 place needs attention on its own row",
    );
  });

  it("one package's bulk update leaves scopes only other packages live in alone", async () => {
    const acme = { scope: "project", root: "/home/x/acme" } as const;
    const shop = { scope: "project", root: "/home/x/shop" } as const;
    vi.mocked(commands.packageUpdate).mockResolvedValue({
      status: "ok",
      data: {
        scope: acme,
        drift: [],
        plan: [],
        notes: [],
        warnings: [],
        safety: [],
        adoptable: ADOPTABLE,
        exits: [],
      },
    });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [] },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
    useUpdatesStore.setState({
      rows: [
        row({ name: "gh", scope: acme }),
        row({ name: "review", scope: shop }),
      ],
      loaded: true,
    });

    await useUpdatesStore
      .getState()
      .updateRows([row({ name: "gh", scope: acme })]);

    expect(vi.mocked(commands.packageUpdate).mock.calls).toEqual([
      [acme, "skill", "gh"],
    ]);
    expect(commands.packageSetRev).not.toHaveBeenCalled();
  });

  it("says so instead of celebrating when every place needs a decision", async () => {
    await useUpdatesStore.getState().updateRows([
      row({
        name: "gh",
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    ]);

    expect(commands.packageUpdate).not.toHaveBeenCalled();
    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      "Nothing to update — 1 place needs attention on its own row",
    );
  });

  it("never moves a hold that belongs to a bundle or parent", async () => {
    const acme = { scope: "project", root: "/home/x/acme" } as const;
    vi.mocked(commands.packageUpdate).mockResolvedValue({
      status: "ok",
      data: {
        scope: acme,
        drift: [],
        plan: [],
        notes: [],
        warnings: [],
        safety: [],
        adoptable: ADOPTABLE,
        exits: [],
      },
    });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [] },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await useUpdatesStore
      .getState()
      .updateRows([
        row({ name: "gh", scope: acme, derived: true, pinned: true }),
        row({ name: "review", scope: acme, derived: true }),
      ]);

    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(vi.mocked(commands.packageUpdate).mock.calls).toEqual([
      [acme, "skill", "review"],
    ]);
    expect(toast.success).toHaveBeenCalledWith(
      "Updated 1 package — 1 place needs attention on its own row",
    );
  });
});
