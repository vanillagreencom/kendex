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
    derived: false,
    forked: false,
    mixed: false,
    removedUpstream: false,
    ...overrides,
  };
}

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

const ready = (remaining: UpdateRow[]) => {
  vi.mocked(commands.applyPlan).mockResolvedValue({ status: "ok", data: view });
  vi.mocked(commands.updatesOverview).mockResolvedValue({
    status: "ok",
    data: { rows: remaining, warnings: [] },
  });
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
  });
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
};

describe("updates store: what the success toast claims", () => {
  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: false });
    vi.clearAllMocks();
  });

  it("says everything is up to date only when nothing is left", async () => {
    ready([]);
    await useUpdatesStore.getState().updateRows([row({ name: "gh" })]);
    expect(toast.success).toHaveBeenCalledWith("Everything is up to date");
  });

  it("names the one package a per-package update touched", async () => {
    ready([row({ name: "review" })]);
    await useUpdatesStore.getState().updateRows([row({ name: "gh" })]);
    expect(toast.success).toHaveBeenCalledWith("Updated gh");
  });

  it("counts packages when news it could not act on remains", async () => {
    const gone = row({
      name: "gone",
      updateAvailable: false,
      removedUpstream: true,
      latest: null,
    });
    ready([gone]);
    await useUpdatesStore
      .getState()
      .updateRows([row({ name: "gh" }), row({ name: "review" }), gone]);
    expect(toast.success).toHaveBeenCalledWith("Updated 2 packages");
  });
});
