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

// Two kinds of read of the same standing, overlapping. Check for updates
// fetches before it answers; a poll reads what the mirrors already say.
// Ranked by one counter the poll wins on arrival, and the check the person
// pressed is thrown away with the screen still showing exactly what they
// asked to replace.
describe("a check and a poll in flight together", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      checking: false,
      loaded: false,
      error: null,
    });
  });

  it("keeps the fetched rows when a poll lands in the middle", async () => {
    let landRefresh!: (
      answer: Awaited<ReturnType<typeof commands.updatesRefresh>>,
    ) => void;
    vi.mocked(commands.updatesRefresh).mockReturnValue(
      new Promise((resolve) => {
        landRefresh = resolve;
      }),
    );
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row({ name: "before-the-fetch" })], warnings: [] },
    });

    const checking = useUpdatesStore.getState().check();
    // The window returns focus while the fetch is still running.
    await useUpdatesStore.getState().load();
    landRefresh({
      status: "ok",
      data: { rows: [row({ name: "fetched" })], warnings: [] },
    });
    await checking;

    expect(useUpdatesStore.getState().rows.map((r) => r.name)).toEqual([
      "fetched",
    ]);
  });

  // The half the first fix missed: a poll that begins during the fetch and
  // returns after it. By then nothing is in flight, so a predicate asking
  // what is running on arrival waves it through with its pre-fetch rows.
  it("keeps the fetched rows when a poll starts mid-fetch and lands after", async () => {
    let landRefresh!: (
      answer: Awaited<ReturnType<typeof commands.updatesRefresh>>,
    ) => void;
    let landPoll!: (
      answer: Awaited<ReturnType<typeof commands.updatesOverview>>,
    ) => void;
    vi.mocked(commands.updatesRefresh).mockReturnValue(
      new Promise((resolve) => {
        landRefresh = resolve;
      }),
    );
    vi.mocked(commands.updatesOverview).mockReturnValue(
      new Promise((resolve) => {
        landPoll = resolve;
      }),
    );

    const checking = useUpdatesStore.getState().check();
    // The window returns focus while the fetch is still running.
    const polling = useUpdatesStore.getState().load();
    landRefresh({
      status: "ok",
      data: { rows: [row({ name: "fetched" })], warnings: [] },
    });
    await checking;
    landPoll({
      status: "ok",
      data: { rows: [row({ name: "before-the-fetch" })], warnings: [] },
    });
    await polling;

    expect(useUpdatesStore.getState().rows.map((r) => r.name)).toEqual([
      "fetched",
    ]);
  });

  it("still lets a poll after the check land", async () => {
    vi.mocked(commands.updatesRefresh).mockResolvedValue({
      status: "ok",
      data: { rows: [row({ name: "fetched" })], warnings: [] },
    });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row({ name: "polled-after" })], warnings: [] },
    });

    await useUpdatesStore.getState().check();
    await useUpdatesStore.getState().load();

    expect(useUpdatesStore.getState().rows.map((r) => r.name)).toEqual([
      "polled-after",
    ]);
  });
});

// A read that follows a write this app made is not a poll: the file moved
// and this is the reading of it. A check already in flight was reading the
// world before that write, so it must not put its rows back afterwards.
describe("a read after a write, with a check already running", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      checking: false,
      loaded: false,
      error: null,
    });
  });

  it("lands, and the older check does not undo it", async () => {
    let landRefresh!: (
      answer: Awaited<ReturnType<typeof commands.updatesRefresh>>,
    ) => void;
    vi.mocked(commands.updatesRefresh).mockReturnValue(
      new Promise((resolve) => {
        landRefresh = resolve;
      }),
    );
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row({ name: "after-the-write" })], warnings: [] },
    });

    // A check is already running when the write happens.
    const checking = useUpdatesStore.getState().check();
    await useUpdatesStore.getState().load({ afterWrite: true });

    expect(useUpdatesStore.getState().rows.map((r) => r.name)).toEqual([
      "after-the-write",
    ]);

    // The check answers for a world that no longer exists.
    landRefresh({
      status: "ok",
      data: { rows: [row({ name: "before-the-write" })], warnings: [] },
    });
    await checking;

    expect(useUpdatesStore.getState().rows.map((r) => r.name)).toEqual([
      "after-the-write",
    ]);
  });
});
