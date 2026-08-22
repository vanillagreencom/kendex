// A read that follows a write outranks a check already in flight: the file
// moved, and a check that started before it would put the pre-write rows
// back. That ranking is earned by the write. An update run that stops at
// its first place has written nothing, so its re-read is a poll like any
// other — claiming otherwise throws away the result of a check the person
// started and leaves the pre-check tables on screen.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { useSettingsStore } from "./settings";
import { useUpdatesStore } from "./updates";
import { applyMany } from "./updates-apply";

vi.mock("@/bindings", () => ({
  commands: {
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    packageSetRev: vi.fn(),
    applyPlan: vi.fn(),
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}));
vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: async () => {} }) },
}));
vi.mock("./audit", () => ({
  useAuditStore: { getState: () => ({ refresh: async () => {} }) },
}));

const held = (name: string): UpdateRow => ({
  scope: { scope: "global" },
  kind: "skill",
  name,
  source: "kendex",
  repo: "owner/catalog",
  repoIdentity: "owner/catalog",
  current: { commit: "a".repeat(40), label: "v1", date: null },
  latest: { commit: "b".repeat(40), label: "v2", date: null },
  updateAvailable: true,
  // Held, so the run reaches `packageSetRev` — the call staged to fail
  // before it writes anything.
  pinned: true,
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
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((keep) => {
    resolve = keep;
  });
  return { promise, resolve };
}

const settle = () => new Promise((done) => setTimeout(done, 0));

beforeEach(() => {
  vi.clearAllMocks();
  useSettingsStore.setState({ settings: { schema: 1, projects: [] } });
  useUpdatesStore.setState({
    rows: [held("before")],
    busy: false,
    checking: false,
    loaded: true,
    error: null,
  });
  vi.mocked(commands.getManifest).mockResolvedValue({
    status: "ok",
    data: { manifest: null, base: null },
  });
  vi.mocked(commands.editorInventory).mockResolvedValue({
    status: "ok",
    data: {
      declaredAgents: [],
      declaredSkills: [],
      availableSkills: [],
      harnesses: [],
      hookEvents: [],
    },
  });
});

describe("a hold toggle the machine refused", () => {
  it("leaves the check it overlapped with standing", async () => {
    const fetched =
      deferred<Awaited<ReturnType<typeof commands.updatesRefresh>>>();
    vi.mocked(commands.updatesRefresh).mockReturnValue(fetched.promise);
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [held("before")], warnings: [] },
    });
    void useUpdatesStore.getState().check();
    await settle();
    expect(useUpdatesStore.getState().checking).toBe(true);

    // Letting a held package follow again is refused: nothing on disk moved.
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "error",
      error: "the hold belongs to a bundle",
    });
    await useUpdatesStore.getState().setAutoUpdate(held("before"), true);

    fetched.resolve({
      status: "ok",
      data: { rows: [held("after the check")], warnings: [] },
    });
    await settle();

    expect(useUpdatesStore.getState().rows.map((r) => r.name)).toEqual([
      "after the check",
    ]);
  });
});

describe("an update run that stopped before writing anything", () => {
  it("leaves the check it overlapped with standing", async () => {
    // The check the person started is still fetching.
    const fetched =
      deferred<Awaited<ReturnType<typeof commands.updatesRefresh>>>();
    vi.mocked(commands.updatesRefresh).mockReturnValue(fetched.promise);
    // Whatever polls meanwhile reads the world as it was before the check.
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [held("before")], warnings: [] },
    });
    void useUpdatesStore.getState().check();
    await settle();
    expect(useUpdatesStore.getState().checking).toBe(true);

    // Update all, refused by the machine at its first place: nothing on
    // disk moved.
    vi.mocked(commands.packageSetRev).mockResolvedValue({
      status: "error",
      error: "the source would not resolve",
    });
    await applyMany([held("before")]);
    expect(commands.applyPlan).not.toHaveBeenCalled();

    // And now the check lands.
    fetched.resolve({
      status: "ok",
      data: { rows: [held("after the check")], warnings: [] },
    });
    await settle();

    expect(useUpdatesStore.getState().rows.map((r) => r.name)).toEqual([
      "after the check",
    ]);
  });
});
