import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { useUpdatesStore } from "./updates";

vi.mock("@/bindings", () => ({
  commands: {
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    updateSetIgnored: vi.fn(),
    packageSetRev: vi.fn(),
    applyPlan: vi.fn(),
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
    current: { commit: "a".repeat(40), label: "v1", date: null },
    latest: { commit: "b".repeat(40), label: "v2", date: null },
    updateAvailable: true,
    pinned: false,
    ignored: false,
    blockedByLocalEdit: false,
    editedHarnesses: [],
    forked: false,
    mixed: false,
    removedUpstream: false,
    ...overrides,
  };
}

describe("updates store: bulk update", () => {
  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: false });
    vi.clearAllMocks();
  });

  it("a bulk update moves holds once each and applies every following scope once", async () => {
    const acme = { scope: "project", root: "/home/x/acme" } as const;
    const shop = { scope: "project", root: "/home/x/shop" } as const;
    const view = {
      scope: { scope: "global" } as const,
      drift: [],
      plan: [],
      notes: [],
      warnings: [],
      safety: [],
      heldBack: [],
      queued: [],
    };
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "ok",
      data: view,
    });
    vi.mocked(commands.applyPlan).mockResolvedValue({
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
      }),
    ]);

    expect(commands.packageSetRev).toHaveBeenCalledTimes(1);
    expect(commands.packageSetRev).toHaveBeenCalledWith(
      acme,
      "skill",
      "gh",
      "b".repeat(40),
    );
    // Moving gh's hold already applied acme, so review came current with
    // it; only the global follower still needs its own apply.
    const applied = vi.mocked(commands.applyPlan).mock.calls.map((c) => c[0]);
    expect(applied).toEqual([{ scope: "global" }]);
    expect(toast.success).toHaveBeenCalledWith(
      "Updated 2 packages — 1 customized place needs a decision",
    );
  });

  it("one package's bulk update leaves scopes only other packages live in alone", async () => {
    const acme = { scope: "project", root: "/home/x/acme" } as const;
    const shop = { scope: "project", root: "/home/x/shop" } as const;
    vi.mocked(commands.applyPlan).mockResolvedValue({
      status: "ok",
      data: {
        scope: acme,
        drift: [],
        plan: [],
        notes: [],
        warnings: [],
        safety: [],
        heldBack: [],
        queued: [],
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

    expect(vi.mocked(commands.applyPlan).mock.calls.map((c) => c[0])).toEqual([
      acme,
    ]);
    expect(commands.packageSetRev).not.toHaveBeenCalled();
  });

  it("says so instead of celebrating when every place needs a decision", async () => {
    await useUpdatesStore.getState().updateRows([
      row({
        name: "gh",
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
      }),
    ]);

    expect(commands.applyPlan).not.toHaveBeenCalled();
    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      "Nothing to update — 1 customized place needs a decision first",
    );
  });
});
