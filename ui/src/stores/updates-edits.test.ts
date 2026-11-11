import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { updateRow } from "@/components/updates-test-rows";
import { ADOPTABLE } from "@/lib/adoptable";
import { FORK_ERROR_TITLE } from "@/lib/copy";
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
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));

const row = (overrides: Partial<UpdateRow>): UpdateRow =>
  updateRow("gh", null, {
    repo: "owner/catalog",
    repoIdentity: "owner/catalog",
    current: { commit: "a".repeat(40), label: "v1", date: null },
    latest: { commit: "b".repeat(40), label: "v2", date: null },
    ...overrides,
  });

describe("updates store: edited places", () => {
  beforeEach(() => {
    // Rows being acted on imply a read that answered; the stale-refusal
    // test below stages the opposite itself.
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      read: READ_LANDED,
    });
    vi.clearAllMocks();
  });

  // A transport rejection never assigns work's error — only the applier
  // sees it, and dropping its return would let the fork and discard flows
  // carry on to their success paths over an IPC failure.
  it("a fork whose transport failed does not proceed as success", async () => {
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.packageFork).mockRejectedValue(new Error("ipc down"));
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
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
    // The machine is read anyway: the call never answered, so nothing says
    // whether the apply ran.
    expect(commands.auditAll).toHaveBeenCalled();
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
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });

    await takeNewVersion(
      row({ blockedByLocalEdit: true, editedHarnesses: ["claude"] }),
    );

    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe("ipc down");
    expect(commands.auditAll).toHaveBeenCalled();
  });

  // Keeping the edits settles the scope after the fork lands, and taking
  // the new version renders behind its apply. Either step failing leaves
  // the write standing, and the failure is said beside it.
  it("says a step behind a landed fork or discard that failed", async () => {
    const written = {
      scope: { scope: "global" as const },
      drift: [],
      plan: [],
      notes: [],
      warnings: [],
      safety: [],
      adoptable: ADOPTABLE,
      exits: [],
      unfinished: "settle the scope: permission denied",
    };
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });
    const edited = row({
      blockedByLocalEdit: true,
      editedHarnesses: ["claude"],
      forkableHarness: "claude",
    });
    const writes = [
      {
        name: "keep as my own",
        answer: () =>
          vi
            .mocked(commands.packageFork)
            .mockResolvedValue({ status: "ok", data: written }),
        act: () => keepAsOwn(edited),
      },
      {
        name: "take the new version",
        answer: () =>
          vi
            .mocked(commands.applyDiscardEdits)
            .mockResolvedValue({ status: "ok", data: written }),
        act: () => takeNewVersion(edited),
      },
    ];
    expect(writes.length).toBeGreaterThan(0);
    for (const write of writes) {
      useProblemsStore.setState({
        dialog: { open: false, title: "", steps: [], actions: [] },
      });
      write.answer();

      await write.act();

      const dialog = useProblemsStore.getState().dialog;
      expect(dialog.open, write.name).toBe(true);
      expect(dialog.message, write.name).toBe(
        "settle the scope: permission denied",
      );
      expect(dialog.title, write.name).not.toBe(FORK_ERROR_TITLE);
    }
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
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: {
        harnesses: [],
        items: [],
        missingProjects: [],
        readProjects: [],
        warnings: [],
      },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
    const edited = {
      blockedByLocalEdit: true,
      editedHarnesses: ["claude" as const],
      forkableHarness: "claude" as const,
    };

    const rows = [
      {
        name: "held",
        subject: row({ ...edited, pinned: true }),
        revision: "b".repeat(40),
      },
      { name: "following", subject: row(edited), revision: null },
      {
        name: "bundle-owned hold",
        subject: row({
          ...edited,
          pinned: true,
          derived: true,
          canTakeLatest: false,
        }),
        revision: null,
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const test of rows) {
      await takeNewVersion(test.subject);
      expect(commands.applyDiscardEdits, test.name).toHaveBeenLastCalledWith(
        { scope: "global" },
        "skill",
        "gh",
        test.revision,
      );
    }
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
    });
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.clearAllMocks();
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: {
        harnesses: [],
        items: [],
        missingProjects: [],
        readProjects: [],
        warnings: [],
      },
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

    const rows = [
      {
        name: "held",
        subject: row({ ...edited, pinned: true }),
        revision: "b".repeat(40),
      },
      { name: "following", subject: row(edited), revision: null },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const test of rows) {
      expect(
        await installAsNew(test.subject, "claude", "gh-mine"),
        test.name,
      ).toBeNull();
      expect(commands.packageForkBeside, test.name).toHaveBeenLastCalledWith(
        { scope: "global" },
        "skill",
        "gh",
        "claude",
        "gh-mine",
        test.revision,
      );
    }
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
    // Read anyway, on `rescan.ts`'s rule.
    expect(commands.auditAll).toHaveBeenCalled();
  });

  // A call that failed on its way never answered: the fork may have
  // landed, so it reads as neither a recorded fork nor a refusal. Handed
  // back as a refusal, the name dialog would stay open for another name,
  // and a second one sent over a fork that did land installs the package
  // twice. The dialog closes, the error dialog says nothing is known, and
  // the rows are read again behind it.
  it("reads a call that never answered as unknown, not as refused", async () => {
    const failures = [
      {
        name: "a plain string, which names no phase",
        answer: () =>
          vi.mocked(commands.packageForkBeside).mockResolvedValue({
            status: "error",
            error: "the IPC channel closed" as never,
          }),
      },
      {
        name: "a rejection",
        answer: () =>
          vi
            .mocked(commands.packageForkBeside)
            .mockRejectedValue(new Error("the IPC channel closed")),
      },
    ];
    expect(failures.length).toBeGreaterThan(0);
    for (const failure of failures) {
      vi.clearAllMocks();
      useProblemsStore.getState().closeError();
      failure.answer();

      expect(
        await installAsNew(row(edited), "claude", "gh-mine"),
        failure.name,
      ).toBeNull();
      const dialog = useProblemsStore.getState().dialog;
      expect(dialog.open, failure.name).toBe(true);
      expect(dialog.message, failure.name).toBe("the IPC channel closed");
      expect(dialog.title, failure.name).not.toBe(FORK_ERROR_TITLE);
      expect(toast.success, failure.name).not.toHaveBeenCalled();
      expect(toast.info, failure.name).not.toHaveBeenCalled();
      expect(commands.updatesOverview, failure.name).toHaveBeenCalled();
      expect(commands.auditAll, failure.name).toHaveBeenCalled();
      expect(useUpdatesStore.getState().busy, failure.name).toBe(false);
    }
  });

  // The fork and its install both landed; the render behind them did not.
  // The install is said, and so is the step.
  it("says a step behind a landed install that failed, beside it", async () => {
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
        unfinished: "render bot instructions: disk full",
      },
    });

    expect(await installAsNew(row(edited), "claude", "gh-mine")).toBeNull();
    expect(toast.success).toHaveBeenCalledWith(
      "Installed gh — your edited copy is now gh-mine",
    );
    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.message).toBe("render bot instructions: disk full");
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

  // The positive half of the refusal above: both of these send
  // `row.latest.commit`, and a read that landed is what makes that value
  // one a write may carry.
  it("lets a discard through once the read has landed", async () => {
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
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: {
        harnesses: [],
        items: [],
        missingProjects: [],
        readProjects: [],
        warnings: [],
      },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await takeNewVersion(
      row({ blockedByLocalEdit: true, editedHarnesses: ["claude"] }),
    );

    expect(commands.applyDiscardEdits).toHaveBeenCalled();
  });
});
