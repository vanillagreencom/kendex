import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { useUpdatesStore } from "./updates";

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

// How a read of the standing lands: what it keeps, what it says when it
// fails, and which of two overlapping reads gets to speak.
describe("reading the update standing", () => {
  beforeEach(() => {
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      loaded: false,
      error: null,
    });
    vi.clearAllMocks();
  });
  // Every screen joining on these rows memoizes on their identity, so a
  // re-read that says the same thing must hand back the same array — an
  // equal copy re-renders the whole table for news that is not news.
  it("hands back the same rows when a re-read says the same thing", async () => {
    const answer = {
      status: "ok" as const,
      data: { rows: [row({})], warnings: [] },
    };
    vi.mocked(commands.updatesOverview).mockResolvedValue(answer);
    await useUpdatesStore.getState().load();
    const first = useUpdatesStore.getState().rows;
    // A fresh array off the wire, saying exactly what the last one did.
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row({})], warnings: [] },
    });
    await useUpdatesStore.getState().load();
    expect(useUpdatesStore.getState().rows).toBe(first);

    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row({ name: "rev" })], warnings: [] },
    });
    await useUpdatesStore.getState().load();
    expect(useUpdatesStore.getState().rows).not.toBe(first);
  });

  it("treats a rejected read as a read that failed", async () => {
    vi.mocked(commands.updatesOverview).mockRejectedValue(
      new Error("no channel"),
    );
    await useUpdatesStore.getState().load();
    expect(useUpdatesStore.getState().error).toContain("no channel");
    expect(useUpdatesStore.getState().loaded).toBe(false);
  });

  // Hand edits reach the Library's marks only through this read, so a
  // failure that leaves no trace shows a table of packages with nothing
  // marked — which reads as "nothing of yours is here".
  it("keeps the reason a load failed, and clears it on the next good one", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValueOnce({
      status: "error",
      error: "no network",
    });
    await useUpdatesStore.getState().load();
    expect(useUpdatesStore.getState().loaded).toBe(false);
    expect(useUpdatesStore.getState().error).toBe("no network");

    vi.mocked(commands.updatesOverview).mockResolvedValueOnce({
      status: "ok",
      data: { rows: [row({})], warnings: [] },
    });
    await useUpdatesStore.getState().load();
    expect(useUpdatesStore.getState().error).toBe(null);
  });

  // A read issued before a fork lands, resolving after it, must not put its
  // pre-resolution rows back: the marks, the notice and the Review count
  // all read them, so a resolved state would reappear.
  it("never lets a superseded read overwrite a newer one", async () => {
    let resolveSlow: (value: unknown) => void = () => {};
    const slow = new Promise((keep) => {
      resolveSlow = keep;
    });
    let call = 0;
    vi.mocked(commands.updatesOverview).mockImplementation(() => {
      call += 1;
      return (
        call === 1
          ? slow
          : Promise.resolve({
              status: "ok",
              data: { rows: [row({ name: "after" })], warnings: [] },
            })
      ) as ReturnType<typeof commands.updatesOverview>;
    });

    const older = useUpdatesStore.getState().load();
    await useUpdatesStore.getState().load();
    expect(useUpdatesStore.getState().rows.map((r) => r.name)).toEqual([
      "after",
    ]);

    resolveSlow({
      status: "ok",
      data: { rows: [row({ name: "before" })], warnings: [] },
    });
    await older;
    expect(useUpdatesStore.getState().rows.map((r) => r.name)).toEqual([
      "after",
    ]);
  });

  // The explicit check has the same shape as the load: a rejection that
  // skips both branches leaves the standing on its last successful values,
  // and the marks go on presenting stale rows as a check that worked.
  it("treats a rejected refresh as a read that failed", async () => {
    useUpdatesStore.setState({ rows: [row({})], loaded: true, error: null });
    vi.mocked(commands.updatesRefresh).mockRejectedValue(
      new Error("no channel"),
    );
    await expect(useUpdatesStore.getState().check()).resolves.toBeUndefined();
    const state = useUpdatesStore.getState();
    expect(state.loaded).toBe(false);
    expect(state.error).toContain("no channel");
    expect(state.checking).toBe(false);
  });
});
