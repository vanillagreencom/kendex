import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type VersionRow } from "@/bindings";
import { VERSION_ERROR_TITLE } from "@/lib/copy";
import { packageVersionActions } from "./package-version-actions";
import { diffHarness } from "./use-package-data";

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
const showError = vi.hoisted(() => vi.fn());
vi.mock("@/stores/problems", () => ({
  useProblemsStore: { getState: () => ({ showError }) },
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
  "The copy in Claude Code was left as it is — settle it on the package page";

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
    expect(toast.info).toHaveBeenCalledWith(HELD_IN_CLAUDE);
  });

  // A refused write is not a write that changed nothing — `lib/rescan.ts`'s
  // header says what does and does not survive a failed apply. A page that
  // returned on the error would go on showing the version it read before
  // the click as the settled one.
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

  // A write that rejects rather than refusing is only ever seen by a
  // wrapper. Unwrapped it said nothing to the person, left the page's own
  // flag up for the life of the view, and skipped the read-back the
  // refusal path above promises happens either way.
  it("answers a rejected write the way it answers a refusal", async () => {
    const reload = vi.fn();
    const setBusy = vi.fn();
    vi.mocked(commands.packageUpdate).mockRejectedValue(new Error("ipc down"));

    packageVersionActions(ref, "gh", false, setBusy, reload).updateToLatest(
      version("b".repeat(40)),
    );

    await vi.waitFor(() => expect(reload).toHaveBeenCalled());
    expect(setBusy.mock.calls).toEqual([[true], [false]]);
    expect(showError).toHaveBeenCalledWith({
      title: VERSION_ERROR_TITLE,
      message: "ipc down",
    });
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
});
