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

const actions = (held: boolean) =>
  packageVersionActions(
    ref,
    "gh",
    held,
    () => {},
    () => {},
  );

describe("packageVersionActions", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("brings a following package current through the single-package apply", async () => {
    vi.mocked(commands.packageUpdate).mockResolvedValue({
      status: "ok",
      data: {
        view: {
          scope: { scope: "global" },
          drift: [],
          plan: [],
          notes: [],
          warnings: [],
          safety: [],
          adoptable: [],
          exits: [],
          error: null,
        },
        heldBack: [],
        removed: [],
        moved: [],
      },
    });
    actions(false).updateToLatest(version("b".repeat(40)));
    await vi.waitFor(() => expect(commands.packageUpdate).toHaveBeenCalled());
    expect(vi.mocked(commands.packageUpdate).mock.calls).toEqual([
      [ref.scope, ref.kind, ref.name],
    ]);
    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(toast.success).toHaveBeenCalledWith("Updated gh");
  });

  it("says what was held back rather than claiming the package moved", async () => {
    vi.mocked(commands.packageUpdate).mockResolvedValue({
      status: "ok",
      data: {
        view: {
          scope: { scope: "global" },
          drift: [],
          plan: [],
          notes: [],
          warnings: [],
          safety: [],
          adoptable: [],
          exits: [],
          error: null,
        },
        removed: [],
        heldBack: [
          {
            kind: "skill",
            name: "gh",
            harness: "claude",
            scope: { scope: "global" },
            state: "conflict",
            detail: "you changed this copy",
            cause: "local-edit",
          },
        ],
        moved: [],
      },
    });
    actions(false).updateToLatest(version("b".repeat(40)));
    await vi.waitFor(() => expect(toast.info).toHaveBeenCalled());
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      "gh was not updated — the copy in Claude Code needs attention on the package page",
    );
  });

  it("moves a held package's hold instead of applying it", async () => {
    const row = version("c".repeat(40));
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "ok",
      data: {
        scope: { scope: "global" },
        drift: [],
        plan: [],
        notes: [],
        warnings: [],
        safety: [],
        adoptable: [],
        exits: [],
        error: null,
      },
    });
    actions(true).updateToLatest(row);
    await vi.waitFor(() => expect(commands.packageSetRev).toHaveBeenCalled());
    expect(vi.mocked(commands.packageSetRev).mock.calls).toEqual([
      [ref.scope, ref.kind, ref.name, row.id],
    ]);
    expect(commands.packageUpdate).not.toHaveBeenCalled();
  });
});
