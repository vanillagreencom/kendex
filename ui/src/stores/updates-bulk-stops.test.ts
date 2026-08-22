import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
import { useUpdatesStore } from "./updates";

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

// Update all is one action over several places. Asked per place as the
// loops run, the first refusal would leave the set half updated — some
// places current, one untouched — from a click that never offered to do
// part of it.
// A hold that failed is a reason not to write anywhere else either. The
// follower loop reaches its command directly, so nothing but this stops it.
describe("a bulk update whose first place fails", () => {
  const acme = { scope: "project", root: "/home/x/acme" } as const;
  const shop = { scope: "project", root: "/home/x/shop" } as const;

  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: false });
    useEditorStore.setState({
      scope: acme,
      draft: null,
      dirty: false,
      held: {},
    });
    vi.clearAllMocks();
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [] },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  });

  it("writes nowhere else", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "error",
      error: "the source would not answer",
    });
    await useUpdatesStore
      .getState()
      .updateRows([
        row({ name: "gh", scope: acme, pinned: true }),
        row({ name: "lint", scope: shop }),
      ]);
    expect(commands.packageSetRev).toHaveBeenCalledTimes(1);
    expect(commands.applyPlan).not.toHaveBeenCalled();
    // The tables still re-read: stopping is not the same as saying nothing.
    expect(commands.updatesOverview).toHaveBeenCalled();
  });
});

// Busy is what holds every update control down. Cleared while the re-reads
// are still running, the controls come back before the tables do and the
// next thing pressed races this one's scan.
describe("the busy flag when a bulk update stops early", () => {
  const acme = { scope: "project", root: "/home/x/acme" } as const;

  it("stays up until the tables have been re-read", async () => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: false });
    useEditorStore.setState({
      scope: acme,
      draft: null,
      dirty: false,
      held: {},
    });
    vi.clearAllMocks();
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "error",
      error: "the source would not answer",
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    let busyDuringReRead: boolean | null = null;
    vi.mocked(commands.updatesOverview).mockImplementation(async () => {
      // Yield first. The command is invoked before the surrounding
      // `finally` can run, so reading the flag here without yielding
      // measures the moment before the question is even asked — and passes
      // whether the cleanup is awaited or not.
      await Promise.resolve();
      busyDuringReRead = useUpdatesStore.getState().busy;
      return { status: "ok", data: { rows: [], warnings: [] } };
    });

    await useUpdatesStore
      .getState()
      .updateRows([row({ name: "gh", scope: acme, pinned: true })]);

    expect(busyDuringReRead).toBe(true);
    expect(useUpdatesStore.getState().busy).toBe(false);
  });
});
