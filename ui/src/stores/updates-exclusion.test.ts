// When a check may run, and when a write may.
//
// A check ranks by when it lands, because it reads the standing after
// fetching every mirror and so saw more than any read still out. That holds
// only while nothing else commits meanwhile: `updates_refresh` builds its
// report once, and a commit landing after that read is not in it. Claiming
// to be newest would put the rows back as they were before the commit — and
// `read` would say `landed` over them, which re-opens every action on rows
// nobody confirmed. So the two never run together.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { packageVersionActions } from "@/components/package/use-package-data";
import { ADOPTABLE } from "@/lib/adoptable";
import { UPDATES_ONE_AT_A_TIME_NOTE } from "@/lib/copy-updates";
import { READ_LANDED } from "@/lib/read-state";
import { useProblemsStore } from "./problems";
import { useUpdatesStore } from "./updates";
import { keepAsOwn } from "./updates-edits";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    updatesOverview: vi.fn(),
    updatesRefresh: vi.fn(),
    updateSetIgnored: vi.fn(),
    packageSetRev: vi.fn(),
    packageUpdate: vi.fn(),
    packageUpdateMany: vi.fn(),
    packageFork: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn(), message: vi.fn() },
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

describe("the check and the writes exclude each other", () => {
  beforeEach(() => {
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      checking: false,
      reading: false,
      pendingFollows: [],
      read: READ_LANDED,
      lastFetched: null,
    });
    vi.clearAllMocks();
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  });

  /** Park a command, handing back the resolver. */
  const park = <T>() => {
    let land!: (value: T) => void;
    const promise = new Promise<T>((resolve) => {
      land = resolve;
    });
    return { promise, land: (value: T) => land(value) };
  };

  /** The scope's view a write answers with; nothing here reads it. */
  const VIEW = {
    scope: { scope: "global" as const },
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    exits: [],
  };
  const APPLIED = {
    status: "ok" as const,
    data: { view: VIEW, heldBack: [], removed: [], moved: [] },
  };
  /** The version a package page's Update moves to. */
  const NEWEST = {
    id: "b".repeat(40),
    label: "v2",
    date: "2026-01-01T00:00:00Z",
    summary: "the newest",
    installed: false,
    newerThanInstalled: true,
  };

  // A check ranks by when it lands, because it reads the standing after
  // fetching every mirror and so saw more than any read still out. That
  // holds only while nothing else commits meanwhile: `updates_refresh`
  // builds its report once, and a commit landing after that read is not in
  // it. Claiming to be newest would put the rows back as they were before
  // the commit — and `read` would say `landed` over them, which is what
  // re-opens every action on rows nobody confirmed. So the two never run
  // together.
  //
  // One case, both directions, every path that commits. `busy` and
  // `checking` each close one direction and neither closes both, and a
  // write that raises no flag is a hole in the same window — which is what
  // the Follow flip, the package page and keep-as-fork each were.
  it("refuses a check while any write is out, and a write while a check is out", async () => {
    const standing = (rows: UpdateRow[]) => ({
      status: "ok" as const,
      data: { rows, warnings: [], lastFetched: null },
    });
    const muted = [row({ ignored: true })];
    vi.mocked(commands.updatesOverview).mockResolvedValue(standing(muted));

    /** Start a check, and answer whether it got as far as fetching. */
    const checkRan = async () => {
      vi.mocked(commands.updatesRefresh).mockClear();
      await useUpdatesStore.getState().check();
      return vi.mocked(commands.updatesRefresh).mock.calls.length > 0;
    };

    // A mute out.
    const mute = park<Awaited<ReturnType<typeof commands.updateSetIgnored>>>();
    vi.mocked(commands.updateSetIgnored).mockReturnValue(mute.promise);
    const muting = useUpdatesStore.getState().setIgnored(row({}), true);
    expect(await checkRan()).toBe(false);
    mute.land(standing(muted));
    await muting;

    // A Follow flip out. Its write goes through the store, but under a
    // setter of its own, so it is the path a page-wide flag most easily
    // misses.
    const flip = park<Awaited<ReturnType<typeof commands.packageSetRev>>>();
    vi.mocked(commands.packageSetRev).mockReturnValue(flip.promise);
    const flipping = useUpdatesStore.getState().setAutoUpdate(row({}), false);
    expect(await checkRan()).toBe(false);
    flip.land(APPLIED);
    await flipping;

    // A package page's Update. It commands the engine straight from the
    // component, under a flag of the page's own that the store cannot see.
    const applying = park<Awaited<ReturnType<typeof commands.packageUpdate>>>();
    vi.mocked(commands.packageUpdate).mockReturnValue(applying.promise);
    const { updateToLatest } = packageVersionActions(
      { scope: { scope: "global" }, kind: "skill", name: "gh" },
      "gh",
      false,
      () => {},
      () => {},
    );
    const updating = updateToLatest(NEWEST);
    expect(await checkRan()).toBe(false);
    applying.land(APPLIED);
    await updating;

    // The other direction: a check out, and every write refuses rather
    // than committing behind a report already built.
    const fetch = park<Awaited<ReturnType<typeof commands.updatesRefresh>>>();
    vi.mocked(commands.updatesRefresh).mockReturnValue(fetch.promise);
    const checking = useUpdatesStore.getState().check();

    vi.mocked(commands.updateSetIgnored).mockClear();
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    await useUpdatesStore.getState().setIgnored(row({}), false);
    expect(commands.updateSetIgnored).not.toHaveBeenCalled();
    // Its own note: the rows are fine and nothing needs checking first —
    // the only thing in the way is the check already running.
    expect(useProblemsStore.getState().dialog.message).toBe(
      UPDATES_ONE_AT_A_TIME_NOTE,
    );

    // Keeping an edited place as a fork copies what is on disk, so it
    // captures nothing off the row — but it commits, which is enough.
    vi.mocked(commands.packageFork).mockClear();
    await keepAsOwn(
      row({ blockedByLocalEdit: true, forkableHarness: "claude" }),
    );
    expect(commands.packageFork).not.toHaveBeenCalled();

    fetch.land(standing([row({})]));
    await checking;
  });

  // `busy` is counted rather than set, because two writes really can be
  // out at once. `updateOne` bars a second one through `rowUnsettled`,
  // which carries the read state, a running check and a flip settling in
  // the row's own scope — never `busy` — so two updates in two scopes are
  // both accepted. `updateRows` reads the same predicate, and a Follow
  // flip takes a second scope's flip for the same reason. A `busy` that
  // whichever finishes first writes false would reopen the check while the
  // other is still committing.
  it("keeps a check refused until the last of two overlapping writes ends", async () => {
    const landed = {
      status: "ok" as const,
      data: { rows: [row({})], warnings: [], lastFetched: null },
    };
    vi.mocked(commands.updatesOverview).mockResolvedValue(landed);

    const first = park<Awaited<ReturnType<typeof commands.packageUpdate>>>();
    const second = park<Awaited<ReturnType<typeof commands.packageUpdate>>>();
    vi.mocked(commands.packageUpdate)
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);

    const one = useUpdatesStore.getState().updateOne(row({}));
    const two = useUpdatesStore
      .getState()
      .updateOne(row({ scope: { scope: "project", root: "/home/me/app" } }));
    // The overlap is measured, not assumed: nothing refused the second.
    expect(commands.packageUpdate).toHaveBeenCalledTimes(2);

    first.land(APPLIED);
    await one;
    expect(useUpdatesStore.getState().busy).toBe(true);

    vi.mocked(commands.updatesRefresh).mockClear();
    await useUpdatesStore.getState().check();
    expect(commands.updatesRefresh).not.toHaveBeenCalled();

    second.land(APPLIED);
    await two;
    expect(useUpdatesStore.getState().busy).toBe(false);
  });

  // The fork is the one write with no row-capture predicate: it copies
  // what is on disk. A check that failed leaves rows on screen nothing
  // confirmed, and that is exactly when the way out of an edited place is
  // wanted — so nothing but the work already running may bar it.
  it("forks an edited place after a check that failed", async () => {
    useUpdatesStore.setState({
      rows: [row({})],
      read: { status: "failed", error: "no network" },
    });
    vi.mocked(commands.packageFork).mockResolvedValue({
      status: "ok",
      data: null,
    } as never);
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row({})], warnings: [], lastFetched: null },
    });

    await keepAsOwn(
      row({ blockedByLocalEdit: true, forkableHarness: "claude" }),
    );

    expect(commands.packageFork).toHaveBeenCalled();
  });
});
