import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type ProjectChanges } from "@/bindings";
import { READ_PENDING } from "@/lib/read-state";
import {
  changesFor,
  commitBlocked,
  pendingCount,
  pendingPaths,
  useProjectChangesStore,
} from "./project-changes";

vi.mock("@/bindings", () => ({
  commands: { projectChangesScan: vi.fn() },
}));

const ROOT = "/home/method/dev/site";

const row = (over: Partial<ProjectChanges> = {}): ProjectChanges => ({
  root: ROOT,
  name: "site",
  state: {
    kind: "pending",
    files: [".claude/CLAUDE.md"],
    shared: [],
    others: 0,
    branch: "main",
    operation: null,
  },
  ...over,
});

beforeEach(() => {
  vi.clearAllMocks();
  useProjectChangesStore.setState({ rows: [], read: READ_PENDING });
});

describe("what each project has waiting", () => {
  it("keeps what the read found and never opens anything", async () => {
    vi.mocked(commands.projectChangesScan).mockResolvedValue({
      status: "ok",
      data: [row()],
    });
    await useProjectChangesStore.getState().refresh([ROOT]);
    const state = useProjectChangesStore.getState();
    expect(state.read.status).toBe("landed");
    expect(pendingCount(changesFor(state.rows, ROOT))).toBe(1);
    expect(pendingPaths(changesFor(state.rows, ROOT))).toEqual([
      ".claude/CLAUDE.md",
    ]);
  });

  // The three answers a surface must never blur. Only a landed read that
  // found nothing may say "no changes"; a read that failed says nothing was
  // checked, and a project the read did not cover has no row at all.
  it("tells nothing pending from nothing known", async () => {
    const rows: {
      name: string;
      row: ProjectChanges | null;
      count: number | null;
    }[] = [
      { name: "clean", row: row({ state: { kind: "clean" } }), count: 0 },
      { name: "pending", row: row(), count: 1 },
      {
        name: "unreadable",
        row: row({
          state: { kind: "unreadable", said: ["fatal: not a git repository"] },
        }),
        count: null,
      },
      { name: "not covered", row: null, count: null },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const one of rows)
      expect(pendingCount(one.row), one.name).toBe(one.count);
  });

  // A read that failed answers for nothing: the rows it had stay put, and
  // the surfaces head them as unconfirmed. Replacing them with none would
  // be a count nobody took.
  it("keeps the rows a failed read could not refresh", async () => {
    vi.mocked(commands.projectChangesScan).mockResolvedValueOnce({
      status: "ok",
      data: [row()],
    });
    await useProjectChangesStore.getState().refresh([ROOT]);
    vi.mocked(commands.projectChangesScan).mockResolvedValueOnce({
      status: "error",
      error: "git is not on the path",
    });
    await useProjectChangesStore.getState().refresh([ROOT]);
    const state = useProjectChangesStore.getState();
    expect(state.rows).toHaveLength(1);
    expect(state.read).toEqual({
      status: "failed",
      error: "git is not on the path",
    });
  });

  it("reads nothing when this machine tracks no project", async () => {
    await useProjectChangesStore.getState().refresh([]);
    expect(commands.projectChangesScan).not.toHaveBeenCalled();
  });

  // The states a commit cannot be made in. The review still opens on them —
  // that is where they are explained and where the changes stay visible.
  it("says where a commit could not land", () => {
    const rows: {
      name: string;
      row: ProjectChanges | null;
      blocked: boolean;
    }[] = [
      { name: "on a branch", row: row(), blocked: false },
      {
        name: "no branch",
        row: row({
          state: {
            kind: "pending",
            files: ["a"],
            shared: [],
            others: 0,
            branch: null,
            operation: null,
          },
        }),
        blocked: true,
      },
      {
        name: "mid-rebase",
        row: row({
          state: {
            kind: "pending",
            files: ["a"],
            shared: [],
            others: 0,
            branch: "main",
            operation: "a rebase",
          },
        }),
        blocked: true,
      },
      {
        name: "unreadable",
        row: row({ state: { kind: "unreadable", said: [] } }),
        blocked: true,
      },
      { name: "not covered", row: null, blocked: true },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const one of rows)
      expect(commitBlocked(one.row), one.name).toBe(one.blocked);
  });
});
