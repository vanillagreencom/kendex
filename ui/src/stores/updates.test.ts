import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { useProblemsStore } from "./problems";
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
    canTakeLatest: true,
    holdOwner: null,
    derived: false,
    forked: false,
    mixed: false,
    removedUpstream: false,
    ...overrides,
  };
}

describe("updates store", () => {
  beforeEach(() => {
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      loaded: false,
      error: null,
    });
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

  // A failed read used to leave only `loaded: false` behind —
  // indistinguishable from a read still on its way, so Home and the badge
  // had nothing to show for it.
  it("keeps why a read failed, and a good read clears it", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "error",
      error: "no network",
    });
    await useUpdatesStore.getState().load();
    expect(useUpdatesStore.getState().error).toBe("no network");
    expect(useUpdatesStore.getState().loaded).toBe(false);

    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [] },
    });
    await useUpdatesStore.getState().load();
    expect(useUpdatesStore.getState().error).toBeNull();
    expect(useUpdatesStore.getState().loaded).toBe(true);
  });

  // A rejected call used to escape the store entirely — no error recorded,
  // the promise discarded by its callers — while a returned refusal landed.
  it("lands a rejected read the same as a returned refusal", async () => {
    const kept = [row({})];
    useUpdatesStore.setState({ rows: kept, loaded: true });
    vi.mocked(commands.updatesOverview).mockRejectedValue(
      new Error("ipc down"),
    );

    await useUpdatesStore.getState().load();

    expect(useUpdatesStore.getState().error).toBe("ipc down");
    expect(useUpdatesStore.getState().loaded).toBe(false);
    expect(useUpdatesStore.getState().rows).toEqual(kept);
  });

  // The explicit check goes through the same single read-application path:
  // refusal and rejection both land as the store's one failure state.
  it("records why a check failed, rejection included", async () => {
    vi.mocked(commands.updatesRefresh).mockResolvedValue({
      status: "error",
      error: "mirror down",
    });
    await useUpdatesStore.getState().check();
    expect(useUpdatesStore.getState().error).toBe("mirror down");
    expect(useUpdatesStore.getState().loaded).toBe(false);
    expect(useUpdatesStore.getState().checking).toBe(false);

    vi.mocked(commands.updatesRefresh).mockRejectedValue(new Error("ipc"));
    await useUpdatesStore.getState().check();
    expect(useUpdatesStore.getState().error).toBe("ipc");
    expect(useUpdatesStore.getState().checking).toBe(false);
  });

  it("ignores a check clicked while one is already running", async () => {
    useUpdatesStore.setState({ checking: true });
    await useUpdatesStore.getState().check();
    expect(commands.updatesRefresh).not.toHaveBeenCalled();
    useUpdatesStore.setState({ checking: false });
  });

  // Reads land in any order: without ordering, a slow mount-time load
  // landing last would overwrite a fresher answer and stamp its stale rows
  // loaded and current.
  it("discards a slow load that lands after a fresher check", async () => {
    let resolveLoad!: (
      value: Awaited<ReturnType<typeof commands.updatesOverview>>,
    ) => void;
    vi.mocked(commands.updatesOverview).mockReturnValue(
      new Promise((resolve) => {
        resolveLoad = resolve;
      }),
    );
    const loading = useUpdatesStore.getState().load();

    const fresh = [row({ name: "fresh" })];
    vi.mocked(commands.updatesRefresh).mockResolvedValue({
      status: "ok",
      data: { rows: fresh, warnings: [] },
    });
    await useUpdatesStore.getState().check();

    resolveLoad({
      status: "ok",
      data: { rows: [row({ name: "stale" })], warnings: [] },
    });
    await loading;

    expect(useUpdatesStore.getState().rows).toEqual(fresh);
    expect(useUpdatesStore.getState().loaded).toBe(true);
  });

  it("discards a slow failed load landing after a fresher answer", async () => {
    let rejectLoad!: (reason: Error) => void;
    vi.mocked(commands.updatesOverview).mockReturnValue(
      new Promise((_, reject) => {
        rejectLoad = reject;
      }),
    );
    const loading = useUpdatesStore.getState().load();

    vi.mocked(commands.updatesRefresh).mockResolvedValue({
      status: "ok",
      data: { rows: [row({})], warnings: [] },
    });
    await useUpdatesStore.getState().check();

    rejectLoad(new Error("ipc down"));
    await loading;

    expect(useUpdatesStore.getState().loaded).toBe(true);
    expect(useUpdatesStore.getState().error).toBeNull();
  });

  it("keeps a mutation's answer over a slower load's", async () => {
    let resolveLoad!: (
      value: Awaited<ReturnType<typeof commands.updatesOverview>>,
    ) => void;
    vi.mocked(commands.updatesOverview).mockReturnValue(
      new Promise((resolve) => {
        resolveLoad = resolve;
      }),
    );
    const loading = useUpdatesStore.getState().load();

    const muted = [row({ ignored: true })];
    vi.mocked(commands.updateSetIgnored).mockResolvedValue({
      status: "ok",
      data: { rows: muted, warnings: [] },
    });
    await useUpdatesStore.getState().setIgnored(row({}), true);

    resolveLoad({
      status: "ok",
      data: { rows: [row({})], warnings: [] },
    });
    await loading;

    expect(useUpdatesStore.getState().rows).toEqual(muted);
  });

  // A refused mute re-read nothing: the rows on screen are still the last
  // good read's answer, and marking them stale would disable Update
  // buttons over a failure that had nothing to do with checking.
  it("a mute that fails leaves the last good read trusted", async () => {
    const kept = [row({})];
    useUpdatesStore.setState({ rows: kept, loaded: true, error: null });
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.updateSetIgnored).mockResolvedValue({
      status: "error",
      error: "manifest busy",
    });

    await useUpdatesStore.getState().setIgnored(row({}), true);

    expect(useUpdatesStore.getState().rows).toEqual(kept);
    expect(useUpdatesStore.getState().loaded).toBe(true);
    expect(useUpdatesStore.getState().error).toBeNull();
    // The refusal still reaches the person, through the error modal.
    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe("manifest busy");
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
        adoptable: ADOPTABLE,
        exits: [],
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
        adoptable: ADOPTABLE,
        exits: [],
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
