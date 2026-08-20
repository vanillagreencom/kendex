import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { useUpdatesStore } from "./updates";
import { keepAsOwn, takeNewVersion } from "./updates-edits";

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

describe("updates store: edited places", () => {
  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: false });
    vi.clearAllMocks();
  });

  it("use new version on a held place moves the hold to latest in the same apply", async () => {
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
    vi.mocked(commands.applyDiscardEdits).mockResolvedValue({
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
    const edited = {
      blockedByLocalEdit: true,
      editedHarnesses: ["claude" as const],
      forkableHarness: "claude" as const,
    };

    await takeNewVersion(row({ ...edited, pinned: true }));
    expect(commands.applyDiscardEdits).toHaveBeenLastCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      "b".repeat(40),
    );

    await takeNewVersion(row(edited));
    expect(commands.applyDiscardEdits).toHaveBeenLastCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      null,
    );

    // A held bundle member: the bundle owns the revision, so the discard
    // runs without moving one.
    await takeNewVersion(row({ ...edited, pinned: true, derived: true }));
    expect(commands.applyDiscardEdits).toHaveBeenLastCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      null,
    );
    expect(commands.packageSetRev).not.toHaveBeenCalled();
  });

  it("keep as my own forks the edited rendering through the store's busy gate", async () => {
    let busyDuring = false;
    vi.mocked(commands.packageFork).mockImplementation(async () => {
      busyDuring = useUpdatesStore.getState().busy;
      return { status: "error", error: "nope" };
    });

    await keepAsOwn(
      row({
        kind: "agent",
        blockedByLocalEdit: true,
        editedHarnesses: ["opencode", "claude"],
        forkableHarness: "claude",
      }),
    );

    expect(commands.packageFork).toHaveBeenCalledWith(
      { scope: "global" },
      "agent",
      "gh",
      "claude",
    );
    expect(busyDuring).toBe(true);
    expect(useUpdatesStore.getState().busy).toBe(false);
  });
});
