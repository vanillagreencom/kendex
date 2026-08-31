import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { UPDATE_NEEDS_CHECK_NOTE } from "@/lib/copy-updates";
import { READ_LANDED, READ_PENDING } from "@/lib/read-state";
import { useProblemsStore } from "./problems";
import { useUpdatesStore } from "./updates";
import { installAsNew, keepAsOwn, takeNewVersion } from "./updates-edits";

vi.mock("@/bindings", async (importOriginal) => ({
  // The generated constants stay real — the update rules read core's own
  // kind list through them, and a copy kept here could go stale unseen.
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    updateSetIgnored: vi.fn(),
    packageSetRev: vi.fn(),
    packageUpdate: vi.fn(),
    applyDiscardEdits: vi.fn(),
    packageFork: vi.fn(),
    packageForkBeside: vi.fn(),
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
    source: "kendex",
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
    noPerPackageUpdate: null,
    ...overrides,
  };
}

describe("updates store: edited places", () => {
  beforeEach(() => {
    // Rows being acted on imply a read that answered; the stale-refusal
    // test below stages the opposite itself.
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      read: READ_LANDED,
      pendingFollows: [],
    });
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
      data: { rows: [], warnings: [], lastFetched: null },
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
      data: { rows: [], warnings: [], lastFetched: null },
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
    useUpdatesStore.setState({ read: READ_PENDING });
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
      data: { rows: [], warnings: [], lastFetched: null },
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

describe("updates store: installing beside an edited place", () => {
  const edited = {
    blockedByLocalEdit: true,
    editedHarnesses: ["claude" as const],
    forkableHarness: "claude" as const,
  };

  beforeEach(() => {
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      read: READ_LANDED,
      pendingFollows: [],
    });
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.clearAllMocks();
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  });

  it("forks the edited rendering under the chosen name, moving a hold to latest", async () => {
    vi.mocked(commands.packageForkBeside).mockResolvedValue({
      status: "ok",
      data: {
        scope: { scope: "global" },
        drift: [],
        plan: [],
        notes: [],
        warnings: [],
        safety: [],
        adoptable: ADOPTABLE,
        exits: [],
      },
    });

    expect(
      await installAsNew(row({ ...edited, pinned: true }), "claude", "gh-mine"),
    ).toBeNull();
    expect(commands.packageForkBeside).toHaveBeenLastCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      "claude",
      "gh-mine",
      "b".repeat(40),
    );

    expect(await installAsNew(row(edited), "claude", "gh-mine")).toBeNull();
    expect(commands.packageForkBeside).toHaveBeenLastCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      "claude",
      "gh-mine",
      null,
    );
    expect(toast.success).toHaveBeenCalledWith(
      "Installed gh — your edited copy is now gh-mine",
    );
    expect(commands.auditAll).toHaveBeenCalled();
    expect(useUpdatesStore.getState().busy).toBe(false);
  });

  // The refusal belongs to the dialog that asked for the name, not to a
  // problems dialog over it.
  it("hands the engine's refusal back instead of raising a dialog", async () => {
    vi.mocked(commands.packageForkBeside).mockResolvedValue({
      status: "error",
      error: { phase: "refused", message: "'docs' already installed" },
    });

    expect(await installAsNew(row(edited), "claude", "docs")).toBe(
      "'docs' already installed",
    );
    expect(useProblemsStore.getState().dialog.open).toBe(false);
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).not.toHaveBeenCalled();
    expect(commands.auditAll).not.toHaveBeenCalled();
  });

  // An error in neither phase — Tauri rejecting an unknown command or bad
  // args hands back a plain string — must never read as "your fork was
  // recorded": it presents as a refusal, claiming nothing happened.
  it("fails closed on an error shape that names no phase", async () => {
    vi.mocked(commands.packageForkBeside).mockResolvedValue({
      status: "error",
      error: "invalid args `newName`" as never,
    });

    expect(await installAsNew(row(edited), "claude", "gh-mine")).toBe(
      "invalid args `newName`",
    );
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).not.toHaveBeenCalled();
    expect(commands.auditAll).not.toHaveBeenCalled();
    expect(useUpdatesStore.getState().busy).toBe(false);
  });

  // A fork the scope recorded but could not render is not a refusal:
  // another name would not help, and the rows now carry the drift. The
  // dialog gets null and closes; the toast says what landed.
  it("treats a failure after the fork was recorded as a partial result, not a refusal", async () => {
    vi.mocked(commands.packageForkBeside).mockResolvedValue({
      status: "error",
      error: { phase: "recorded", message: "render refused: disk full" },
    });

    expect(await installAsNew(row(edited), "claude", "gh-mine")).toBeNull();
    expect(toast.info).toHaveBeenCalledWith(
      "Your edited copy is now gh-mine, but gh didn't install: render refused: disk full.",
    );
    expect(toast.success).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.open).toBe(false);
    // The refreshes run: what landed is on disk and the rows must say so.
    expect(commands.updatesOverview).toHaveBeenCalled();
    expect(commands.auditAll).toHaveBeenCalled();
  });

  // The hold moves only when it is this declaration's to move.
  it("leaves the hold alone when the newest is not this place's to take", async () => {
    vi.mocked(commands.packageForkBeside).mockResolvedValue({
      status: "error",
      error: { phase: "refused", message: "nope" },
    });
    await installAsNew(
      row({ ...edited, pinned: true, canTakeLatest: false }),
      "claude",
      "gh-mine",
    );
    expect(commands.packageForkBeside).toHaveBeenLastCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      "claude",
      "gh-mine",
      null,
    );
  });

  it("refuses rows a failed check left behind, before any call", async () => {
    useUpdatesStore.setState({ read: READ_PENDING });
    expect(await installAsNew(row(edited), "claude", "gh-mine")).toBe(
      UPDATE_NEEDS_CHECK_NOTE,
    );
    expect(commands.packageForkBeside).not.toHaveBeenCalled();
  });

  // Both of these send row.latest.commit off a row.pinned the settling flip
  // may have painted, and stale(row) is their only guard: the scope the
  // flip is applying holds, and every other scope carries on.
  it("holds a discard and an install-beside while a flip settles in that scope", async () => {
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    useUpdatesStore.setState({
      pendingFollows: [
        {
          id: 1,
          scope: { scope: "global" },
          kind: "skill",
          name: "other",
          pinned: true,
        },
      ],
    });
    const edited = row({
      blockedByLocalEdit: true,
      editedHarnesses: ["claude"],
      forkableHarness: "claude",
    });

    await takeNewVersion(edited);
    expect(commands.applyDiscardEdits).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.message).toBe(
      UPDATE_NEEDS_CHECK_NOTE,
    );
    expect(await installAsNew(edited, "claude", "gh-mine")).toBe(
      UPDATE_NEEDS_CHECK_NOTE,
    );
    expect(commands.packageForkBeside).not.toHaveBeenCalled();
  });

  it("lets a discard through while the flip settles in another scope", async () => {
    useUpdatesStore.setState({
      pendingFollows: [
        {
          id: 1,
          scope: { scope: "project", root: "/home/me/app" },
          kind: "skill",
          name: "gh",
          pinned: true,
        },
      ],
    });
    vi.mocked(commands.applyDiscardEdits).mockResolvedValue({
      status: "ok",
      data: {
        scope: { scope: "global" },
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
      data: { rows: [], warnings: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await takeNewVersion(
      row({ blockedByLocalEdit: true, editedHarnesses: ["claude"] }),
    );

    expect(commands.applyDiscardEdits).toHaveBeenCalled();
  });
});
