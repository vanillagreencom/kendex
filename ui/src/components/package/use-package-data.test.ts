import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type VersionRow } from "@/bindings";
import { diffHarness, packageVersionActions } from "./use-package-data";

describe("diffHarness", () => {
  it("reads the rendering the comparison names, else the primary one", () => {
    const edited = {
      mode: "diff" as const,
      from: "a",
      to: "installed",
      fromLabel: "v1",
      toLabel: "your edits in OpenCode",
      harness: "opencode" as const,
    };
    expect(diffHarness(edited, "claude")).toBe("opencode");
    expect(diffHarness({ ...edited, harness: undefined }, "claude")).toBe(
      "claude",
    );
    expect(diffHarness({ mode: "files", file: null }, "claude")).toBe("claude");
    expect(diffHarness({ mode: "files", file: null }, null)).toBeNull();
  });
});

vi.mock("@/bindings", () => ({
  commands: {
    packageUpdate: vi.fn(),
    packageSetRev: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), info: vi.fn(), error: vi.fn() },
}));
vi.mock("@/stores/scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));
vi.mock("@/stores/audit", () => ({
  useAuditStore: { getState: () => ({ refresh: vi.fn() }) },
}));
vi.mock("@/stores/problems", () => ({
  useProblemsStore: { getState: () => ({ showError: vi.fn() }) },
}));

const ref = {
  scope: { scope: "global" } as const,
  kind: "skill" as const,
  name: "gh",
};

const version = (id: string): VersionRow => ({
  id,
  label: "v2",
  date: "2026-01-01",
  summary: "two",
  installed: false,
  newerThanInstalled: true,
});

const actions = (held: boolean, reload: () => void = () => {}) =>
  packageVersionActions(ref, "gh", held, () => {}, reload);

const VIEW = {
  scope: { scope: "global" } as const,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: [],
  exits: [],
  error: null,
};

const conflict = (harness: "claude" | "codex") => ({
  kind: "skill" as const,
  name: "gh",
  harness,
  scope: { scope: "global" } as const,
  state: "conflict" as const,
  detail: "you changed this copy",
  cause: "local-edit" as const,
});

const stale = (harness: "claude" | "codex") => ({
  ...conflict(harness),
  state: "stale" as const,
  detail: "behind its source",
  cause: null,
});

/** What a single-package apply answers with — the update command and the
 *  version switch alike, so a test names the parts it cares about. */
const answer = (parts: {
  heldBack?: ReturnType<typeof conflict>[];
  removed?: ReturnType<typeof conflict>[];
  moved?: ReturnType<typeof stale>[];
}) =>
  ({
    status: "ok",
    data: { view: VIEW, heldBack: [], removed: [], moved: [], ...parts },
  }) as never;

const HELD_IN_CLAUDE =
  "the copy in Claude Code needs attention on the package page";

describe("packageVersionActions", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("brings a following package current through the single-package apply", async () => {
    vi.mocked(commands.packageUpdate).mockResolvedValue(
      answer({ moved: [stale("claude")] }),
    );
    actions(false).updateToLatest(version("b".repeat(40)));
    // Waits on the outcome rather than the call: the write is awaited
    // through a wrapper, so the command having been called says nothing
    // about the answer having landed.
    await vi.waitFor(() => expect(toast.success).toHaveBeenCalled());
    expect(vi.mocked(commands.packageUpdate).mock.calls).toEqual([
      [ref.scope, ref.kind, ref.name],
    ]);
    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(toast.success).toHaveBeenCalledWith("Updated gh");
  });

  it("says what was held back rather than claiming the package moved", async () => {
    vi.mocked(commands.packageUpdate).mockResolvedValue(
      answer({ heldBack: [conflict("claude")] }),
    );
    actions(false).updateToLatest(version("b".repeat(40)));
    await vi.waitFor(() => expect(toast.info).toHaveBeenCalled());
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      `gh was not updated — ${HELD_IN_CLAUDE}`,
    );
  });

  // A refused write is not a write that changed nothing. `package_set_rev`
  // persists the revision through `set_rev_with` and only then runs the
  // apply, so an apply that fails answers with an error over a manifest
  // that already moved. A page that returned on the error would go on
  // showing the version it read before the click as the settled one.
  it("reads the package back when the write is refused", async () => {
    const reload = vi.fn();
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "error",
      error: "the apply could not finish",
    } as never);

    actions(false, reload).switchTo(version("c".repeat(40)));
    await vi.waitFor(() => expect(reload).toHaveBeenCalled());

    expect(toast.success).not.toHaveBeenCalled();
  });

  // The control the held cases below are read against: a switch the plan
  // wrote everywhere still says so, and says which version it landed on.
  it("says a version switch the plan wrote landed", async () => {
    const row = version("c".repeat(40));
    vi.mocked(commands.packageSetRev).mockResolvedValue(
      answer({ moved: [stale("claude")] }),
    );
    actions(false).switchTo(row);
    await vi.waitFor(() => expect(toast.success).toHaveBeenCalled());
    expect(vi.mocked(commands.packageSetRev).mock.calls).toEqual([
      [ref.scope, ref.kind, ref.name, row.id],
    ]);
    expect(toast.success).toHaveBeenCalledWith("Updated gh to v2");
    expect(toast.info).not.toHaveBeenCalled();
  });

  // The manifest took the new hold and the files did not move with it.
  // Saying "Updated" here is the bug this whole path answers.
  it("does not call a version switch updated when the plan held the copy back", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue(
      answer({ heldBack: [conflict("claude")] }),
    );
    actions(false).switchTo(version("c".repeat(40)));
    await vi.waitFor(() => expect(toast.info).toHaveBeenCalled());
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      `gh is set to v2, but nothing was written — ${HELD_IN_CLAUDE}`,
    );
  });

  it("names the tool a switch could not reach when it wrote the others", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue(
      answer({ heldBack: [conflict("claude")], moved: [stale("codex")] }),
    );
    actions(false).switchTo(version("c".repeat(40)));
    await vi.waitFor(() => expect(toast.success).toHaveBeenCalled());
    expect(toast.success).toHaveBeenCalledWith(
      `Updated gh to v2 — ${HELD_IN_CLAUDE}`,
    );
  });

  it("moves a held package's hold instead of applying it", async () => {
    const row = version("c".repeat(40));
    vi.mocked(commands.packageSetRev).mockResolvedValue(
      answer({ moved: [stale("claude")] }),
    );
    actions(true).updateToLatest(row);
    await vi.waitFor(() => expect(toast.success).toHaveBeenCalled());
    expect(vi.mocked(commands.packageSetRev).mock.calls).toEqual([
      [ref.scope, ref.kind, ref.name, row.id],
    ]);
    expect(commands.packageUpdate).not.toHaveBeenCalled();
    expect(toast.success).toHaveBeenCalledWith("Updated gh to v2");
  });

  // Update on a held package is a hold move, and a hold move can be
  // refused on disk exactly as an update can.
  it("does not call Update on a held package updated when the copy was held back", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue(
      answer({ heldBack: [conflict("claude")] }),
    );
    actions(true).updateToLatest(version("c".repeat(40)));
    await vi.waitFor(() => expect(toast.info).toHaveBeenCalled());
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      `gh is set to v2, but nothing was written — ${HELD_IN_CLAUDE}`,
    );
  });

  it("says Follow source landed when the plan wrote the package", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue(
      answer({ moved: [stale("claude")] }),
    );
    actions(true).follow();
    await vi.waitFor(() => expect(toast.success).toHaveBeenCalled());
    expect(vi.mocked(commands.packageSetRev).mock.calls).toEqual([
      [ref.scope, ref.kind, ref.name, null],
    ]);
    expect(toast.success).toHaveBeenCalledWith("Now following its source");
  });

  // The manifest follows again either way; the toast may not stay silent
  // about a copy the apply could not move.
  it("says Follow source wrote nothing when the copy was held back", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue(
      answer({ heldBack: [conflict("claude")] }),
    );
    actions(true).follow();
    await vi.waitFor(() => expect(toast.info).toHaveBeenCalled());
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      `Now following its source, but nothing was written — ${HELD_IN_CLAUDE}`,
    );
  });

  it("says a copy that went to the trash was not replaced", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue(
      answer({ removed: [conflict("claude")] }),
    );
    actions(false).switchTo(version("c".repeat(40)));
    await vi.waitFor(() => expect(toast.error).toHaveBeenCalled());
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.error).toHaveBeenCalledWith(
      "gh could not be installed — the copy in Claude Code went to the trash and nothing replaced it",
    );
  });
});
