import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { UPDATE_NEEDS_CHECK_NOTE } from "@/lib/copy-updates";
import { useProblemsStore } from "./problems";
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
    canTakeLatest: true,
    holdOwner: null,
    derived: false,
    forked: false,
    mixed: false,
    removedUpstream: false,
    ...overrides,
  };
}

describe("updates store: edited places", () => {
  beforeEach(() => {
    // Rows being acted on imply a read that answered; the stale-refusal
    // test below stages the opposite itself.
    useUpdatesStore.setState({ rows: [], busy: false, loaded: true });
    vi.clearAllMocks();
  });

  // A transport rejection never assigns work's error — only the applier
  // sees it, and dropping its return let the fork and discard flows carry
  // on to their success paths over an IPC failure.
  it("a fork whose transport failed does not proceed as success", async () => {
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.packageFork).mockRejectedValue(new Error("ipc down"));
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [] },
    });

    await keepAsOwn(
      row({
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        forkableHarness: "claude",
      }),
    );

    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe("ipc down");
    // run() stops at the failure instead of refreshing as if it landed.
    expect(commands.auditAll).not.toHaveBeenCalled();
  });

  it("a discard whose transport failed surfaces the failure", async () => {
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.applyDiscardEdits).mockRejectedValue(
      new Error("ipc down"),
    );
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [] },
    });

    await takeNewVersion(
      row({ blockedByLocalEdit: true, editedHarnesses: ["claude"] }),
    );

    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe("ipc down");
    expect(commands.auditAll).not.toHaveBeenCalled();
  });

  // The action boundary owns the guarantee: a confirmation opened before
  // a check failed still holds a retained row whose latest nobody
  // confirmed — the store refuses it however the dialog got there.
  it("refuses to discard edits from rows a failed check left behind", async () => {
    useUpdatesStore.setState({ loaded: false });
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });

    await takeNewVersion(
      row({
        blockedByLocalEdit: true,
        editedHarnesses: ["claude"],
        pinned: true,
      }),
    );

    expect(commands.applyDiscardEdits).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe(
      UPDATE_NEEDS_CHECK_NOTE,
    );
  });

  it("use new version on a held place moves the hold to latest in the same apply", async () => {
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
    await takeNewVersion(
      row({ ...edited, pinned: true, derived: true, canTakeLatest: false }),
    );
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
