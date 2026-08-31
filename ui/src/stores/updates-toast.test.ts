import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { READ_LANDED } from "@/lib/read-state";
import { useUpdatesStore } from "./updates";

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
    packageUpdateMany: vi.fn(),
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

const ready = (remaining: UpdateRow[]) => {
  vi.mocked(commands.packageUpdateMany).mockImplementation(
    async (_scope, targets) => ({
      status: "ok",
      data: {
        view,
        packages: targets.map((target) => ({
          kind: target.kind,
          name: target.name,
          heldBack: [],
          removed: [],
          moved: [],
        })),
      },
    }),
  );
  vi.mocked(commands.updatesOverview).mockResolvedValue({
    status: "ok",
    data: { rows: remaining, warnings: [], lastFetched: null },
  });
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
  });
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
};

describe("updates store: what the success toast claims", () => {
  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, read: READ_LANDED });
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

describe("updates store: a package the plan held back", () => {
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
    cause: "upstream-changed" as const,
  });

  const held = (update: {
    heldBack: ReturnType<typeof conflict>[];
    removed?: ReturnType<typeof conflict>[];
    moved: ReturnType<typeof stale>[];
  }) => {
    ready([]);
    vi.mocked(commands.packageUpdate).mockResolvedValue({
      status: "ok",
      data: { view, removed: [], ...update },
    });
  };

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, read: READ_LANDED });
    vi.clearAllMocks();
  });

  it("never claims a package was updated when nothing moved for it", async () => {
    held({ heldBack: [conflict("claude")], moved: [] });
    await useUpdatesStore.getState().updateOne(row({ name: "gh" }));
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      "gh was not updated — the copy in Claude Code needs attention on the package page",
    );
  });

  // A pinned row moves its hold instead of running the update, and that
  // write is refused on disk for the same reasons — so the row's toast
  // reads the hold move's own report rather than the click.
  it("never claims a pinned package was updated when its copy stayed", async () => {
    ready([]);
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "ok",
      data: { view, heldBack: [conflict("claude")], removed: [], moved: [] },
    });
    await useUpdatesStore
      .getState()
      .updateOne(row({ name: "gh", pinned: true }));
    expect(commands.packageUpdate).not.toHaveBeenCalled();
    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(
      "gh was not updated — the copy in Claude Code needs attention on the package page",
    );
  });

  it("names the tool still holding it when the other copies moved", async () => {
    held({ heldBack: [conflict("codex")], moved: [stale("claude")] });
    await useUpdatesStore.getState().updateOne(row({ name: "gh" }));
    expect(toast.success).toHaveBeenCalledWith(
      "Updated gh — the copy in Codex needs attention on the package page",
    );
  });

  it("says the plain line when the package moved everywhere", async () => {
    held({ heldBack: [], moved: [stale("claude")] });
    await useUpdatesStore.getState().updateOne(row({ name: "gh" }));
    expect(toast.success).toHaveBeenCalledWith("Updated gh");
  });
});

describe("updates store: a copy the run took away", () => {
  const conflict = (harness: "claude" | "codex") => ({
    kind: "skill" as const,
    name: "gh",
    harness,
    scope: { scope: "global" } as const,
    state: "conflict" as const,
    // The refusal's own words: nothing of the person's was in the files,
    // so the old copy goes and nothing is written back.
    detail: "the previous installation will be moved to the trash",
    cause: null,
  });

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, read: READ_LANDED });
    vi.clearAllMocks();
  });

  it("says the copy went to the trash instead of calling it held", async () => {
    ready([]);
    vi.mocked(commands.packageUpdate).mockResolvedValue({
      status: "ok",
      data: { view, heldBack: [], removed: [conflict("claude")], moved: [] },
    });

    await useUpdatesStore.getState().updateOne(row({ name: "gh" }));

    expect(toast.success).not.toHaveBeenCalled();
    expect(toast.info).not.toHaveBeenCalled();
    expect(toast.error).toHaveBeenCalledWith(
      "gh could not be installed — the copy in Claude Code went to the trash and nothing replaced it",
    );
  });
});
