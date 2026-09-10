import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type ProjectChanges } from "@/bindings";
import {
  READ_LANDED,
  READ_PENDING,
  type ReadState,
  readFailed,
} from "@/lib/read-state";
import {
  changesFor,
  commitBlocked,
  pendingCount,
  pendingPaths,
  type Sureness,
  surenessOf,
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

// The registry emptied while a read of the old list was still out. That
// read describes projects nobody tracks now, and landing it afterwards puts
// their rows back on every card.
describe("an emptied registry", () => {
  it("supersedes a read that has not answered yet", async () => {
    let answer: (value: { status: "ok"; data: ProjectChanges[] }) => void =
      () => {};
    vi.mocked(commands.projectChangesScan).mockReturnValue(
      new Promise((resolve) => {
        answer = resolve;
      }) as ReturnType<typeof commands.projectChangesScan>,
    );
    const out = useProjectChangesStore.getState().refresh([ROOT]);
    // The projects are unregistered, and that answer lands first.
    await useProjectChangesStore.getState().refresh([]);
    expect(useProjectChangesStore.getState().rows).toEqual([]);

    answer({ status: "ok", data: [row()] });
    await out;
    expect(
      useProjectChangesStore.getState().rows,
      "a read of the old list landed after the registry emptied",
    ).toEqual([]);
  });
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

// Four states, and drawing any two the same is how a project kendex could
// not check comes to look like a clean one. Every surface reads them from
// here, so the table is the contract.
describe("how sure a surface may be about one project", () => {
  const pending = row();
  const clean = row({ state: { kind: "clean" } });
  const unreadable = row({
    state: { kind: "unreadable", said: ["fatal: bad object"] },
  });

  it("tells waiting, known, stale and unknown apart", () => {
    const rows: {
      name: string;
      rows: ProjectChanges[];
      read: ReadState;
      is: Sureness;
    }[] = [
      { name: "no read yet", rows: [], read: READ_PENDING, is: "waiting" },
      {
        name: "no read yet, rows kept",
        rows: [pending],
        read: READ_PENDING,
        is: "waiting",
      },
      {
        name: "landed, pending",
        rows: [pending],
        read: READ_LANDED,
        is: "known",
      },
      { name: "landed, clean", rows: [clean], read: READ_LANDED, is: "known" },
      // The backend skipped it, so the landed read carries no row for it.
      { name: "landed, no row", rows: [], read: READ_LANDED, is: "unknown" },
      // Its own read refused, whatever the read as a whole did.
      {
        name: "landed, unreadable row",
        rows: [unreadable],
        read: READ_LANDED,
        is: "unknown",
      },
      // A row from the last landed read, under a read that has since failed.
      {
        name: "failed over a prior row",
        rows: [pending],
        read: readFailed("git is not on the path"),
        is: "stale",
      },
      // A failure with nothing behind it knows nothing at all.
      {
        name: "failed, no row",
        rows: [],
        read: readFailed("git is not on the path"),
        is: "unknown",
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const one of rows)
      expect(
        surenessOf({ rows: one.rows, read: one.read }, ROOT),
        one.name,
      ).toBe(one.is);
  });
});
