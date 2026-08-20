import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import {
  hiddenUpdates,
  useUpdatesStore,
  visibleUpdateCount,
  visibleUpdates,
} from "./updates";

vi.mock("@/bindings", () => ({
  commands: {
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    updateSetIgnored: vi.fn(),
    packageSetRev: vi.fn(),
    applyPlan: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn() },
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
    derived: false,
    forked: false,
    mixed: false,
    removedUpstream: false,
    ...overrides,
  };
}

describe("updates store", () => {
  beforeEach(() => {
    useUpdatesStore.setState({ rows: [], busy: false, loaded: false });
    vi.clearAllMocks();
  });

  it("counts only unmuted updates for the badge — held ones still count", () => {
    const rows = [
      row({ name: "a" }),
      row({ name: "b", pinned: true }),
      row({ name: "c", ignored: true }),
      row({ name: "d", updateAvailable: false }),
    ];
    expect(visibleUpdateCount(rows)).toBe(2);
    expect(visibleUpdates(rows).map((r) => r.name)).toEqual(["a", "b"]);
    expect(hiddenUpdates(rows).map((r) => r.name)).toEqual(["c"]);
  });

  it("a package gone from its source or with mixed installs is news even without an update", () => {
    const rows = [
      row({ name: "gone", updateAvailable: false, removedUpstream: true }),
      row({ name: "split", updateAvailable: false, mixed: true }),
      row({
        name: "muted-gone",
        updateAvailable: false,
        removedUpstream: true,
        ignored: true,
      }),
    ];
    expect(visibleUpdates(rows).map((r) => r.name)).toEqual(["gone", "split"]);
    expect(hiddenUpdates(rows).map((r) => r.name)).toEqual(["muted-gone"]);
    expect(visibleUpdateCount(rows)).toBe(2);
  });

  it("muting keeps the row, flagged — and unmuting brings it back", async () => {
    const muted = [row({ ignored: true })];
    vi.mocked(commands.updateSetIgnored).mockResolvedValue({
      status: "ok",
      data: { rows: muted, warnings: [] },
    });
    useUpdatesStore.setState({ rows: [row({})], loaded: true });

    await useUpdatesStore.getState().setIgnored(row({}), true);

    expect(commands.updateSetIgnored).toHaveBeenCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      "owner/catalog",
      true,
    );
    expect(useUpdatesStore.getState().rows).toEqual(muted);
    expect(visibleUpdateCount(useUpdatesStore.getState().rows)).toBe(0);
  });

  it("updating a held package moves its hold to the latest version", async () => {
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "ok",
      data: {
        scope: { scope: "global" },
        drift: [],
        plan: [],
        notes: [],
        warnings: [],
        safety: [],
        heldBack: [],
        queued: [],
      },
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

    await useUpdatesStore.getState().updateOne(row({ pinned: true }));

    expect(commands.packageSetRev).toHaveBeenCalledWith(
      { scope: "global" },
      "skill",
      "gh",
      "b".repeat(40),
    );
    expect(commands.applyPlan).not.toHaveBeenCalled();
  });

  it("updating a following package applies its scope", async () => {
    vi.mocked(commands.applyPlan).mockResolvedValue({
      status: "ok",
      data: {
        scope: { scope: "global" },
        drift: [],
        plan: [],
        notes: [],
        warnings: [],
        safety: [],
        heldBack: [],
        queued: [],
      },
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

    await useUpdatesStore.getState().updateOne(row({}));

    expect(commands.applyPlan).toHaveBeenCalledWith(
      { scope: "global" },
      false,
      [],
    );
    expect(commands.packageSetRev).not.toHaveBeenCalled();
  });
});
