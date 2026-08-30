import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { UPDATE_NEEDS_CHECK_NOTE } from "@/lib/copy-updates";
import {
  hiddenUpdates,
  visibleUpdateCount,
  visibleUpdates,
} from "@/lib/update-groups";
import { useProblemsStore } from "./problems";
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

describe("updates store", () => {
  beforeEach(() => {
    // Rows being acted on imply a read that answered; tests staging the
    // opposite set loaded themselves.
    useUpdatesStore.setState({
      rows: [],
      busy: false,
      loaded: true,
      error: null,
      lastFetched: null,
    });
    vi.clearAllMocks();
  });

  // The age is the middle link of the round trip: the command reports it,
  // the store has to carry it, the page draws it. Only `landOk` moves it,
  // for every landing kind, and a store that quietly dropped it would leave
  // the page saying "Not checked for updates yet" over a check that ran.
  const CHECKED_AT = 1_700_000_000;

  it("lands the age a read reports", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row({})], warnings: [], lastFetched: CHECKED_AT },
    });
    await useUpdatesStore.getState().load();
    expect(useUpdatesStore.getState().lastFetched).toBe(CHECKED_AT);
  });

  // The refresh lands on the side-effect chain rather than the plain-read
  // path, so it carries the age through different code.
  it("lands the age a check reports", async () => {
    vi.mocked(commands.updatesRefresh).mockResolvedValue({
      status: "ok",
      data: { rows: [row({})], warnings: [], lastFetched: CHECKED_AT },
    });
    await useUpdatesStore.getState().check();
    expect(useUpdatesStore.getState().lastFetched).toBe(CHECKED_AT);
  });

  // A check that failed fetched nothing, so the age it had is still when
  // these rows were last true — dropping it would report a check nobody ran.
  it("keeps the age it had when a check fails", async () => {
    useUpdatesStore.setState({ lastFetched: CHECKED_AT });
    vi.mocked(commands.updatesRefresh).mockResolvedValue({
      status: "error",
      error: "no network",
    });
    await useUpdatesStore.getState().check();
    expect(useUpdatesStore.getState().lastFetched).toBe(CHECKED_AT);
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
      data: { rows: [], warnings: [], lastFetched: null },
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
      data: { rows: fresh, warnings: [], lastFetched: null },
    });
    await useUpdatesStore.getState().check();

    resolveLoad({
      status: "ok",
      data: { rows: [row({ name: "stale" })], warnings: [], lastFetched: null },
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
      data: { rows: [row({})], warnings: [], lastFetched: null },
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
      data: { rows: muted, warnings: [], lastFetched: null },
    });
    await useUpdatesStore.getState().setIgnored(row({}), true);

    resolveLoad({
      status: "ok",
      data: { rows: [row({})], warnings: [], lastFetched: null },
    });
    await loading;

    expect(useUpdatesStore.getState().rows).toEqual(muted);
  });

  // A refresh fetches every source before answering, so its result is
  // fresher than any plain read's however late that read began: a load
  // started after a slow check reads the old mirrors, and landing first
  // must not make its staler rows the answer.
  it("a slow check's fresh answer survives a later-started load", async () => {
    let resolveCheck!: (
      value: Awaited<ReturnType<typeof commands.updatesRefresh>>,
    ) => void;
    vi.mocked(commands.updatesRefresh).mockReturnValue(
      new Promise((resolve) => {
        resolveCheck = resolve;
      }),
    );
    const checking = useUpdatesStore.getState().check();

    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row({ name: "stale" })], warnings: [], lastFetched: null },
    });
    await useUpdatesStore.getState().load();

    const fresh = [row({ name: "fresh" })];
    resolveCheck({
      status: "ok",
      data: { rows: fresh, warnings: [], lastFetched: null },
    });
    await checking;

    expect(useUpdatesStore.getState().rows).toEqual(fresh);
  });

  // The symmetric interleaving: the mutation begins first, a read lands
  // its pre-mutation snapshot in between, and the mutation's overview —
  // the state after its commit — lands last. Ranking it by when it began
  // would discard it and leave the screen contradicting the backend.
  it("a mutation's answer survives a read that lands before it", async () => {
    let resolveMutation!: (
      value: Awaited<ReturnType<typeof commands.updateSetIgnored>>,
    ) => void;
    vi.mocked(commands.updateSetIgnored).mockReturnValue(
      new Promise((resolve) => {
        resolveMutation = resolve;
      }),
    );
    const muting = useUpdatesStore.getState().setIgnored(row({}), true);

    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row({})], warnings: [], lastFetched: null },
    });
    await useUpdatesStore.getState().load();

    const muted = [row({ ignored: true })];
    resolveMutation({
      status: "ok",
      data: { rows: muted, warnings: [], lastFetched: null },
    });
    await muting;

    expect(useUpdatesStore.getState().rows).toEqual(muted);
  });

  // Side-effecting operations run one at a time: the second command is
  // not sent until the first answer has landed, so a first response
  // arriving late can never overwrite the second commit's newer state.
  it("lands overlapping mutations in commit order", async () => {
    let resolveFirst!: (
      value: Awaited<ReturnType<typeof commands.updateSetIgnored>>,
    ) => void;
    const secondState = [row({})];
    vi.mocked(commands.updateSetIgnored)
      .mockReturnValueOnce(
        new Promise((resolve) => {
          resolveFirst = resolve;
        }),
      )
      .mockResolvedValueOnce({
        status: "ok",
        data: { rows: secondState, warnings: [], lastFetched: null },
      });

    const first = useUpdatesStore.getState().setIgnored(row({}), true);
    const second = useUpdatesStore.getState().setIgnored(row({}), false);
    await vi.waitFor(() =>
      expect(commands.updateSetIgnored).toHaveBeenCalledTimes(1),
    );

    resolveFirst({
      status: "ok",
      data: { rows: [row({ ignored: true })], warnings: [], lastFetched: null },
    });
    await first;
    await second;

    expect(commands.updateSetIgnored).toHaveBeenCalledTimes(2);
    expect(useUpdatesStore.getState().rows).toEqual(secondState);
  });

  // A mutation still in flight counts too: its landing will replace these
  // rows, so an update accepted now would run on captured arguments.
  it("refuses an update while another mutation is in flight", async () => {
    let resolveMute!: (
      value: Awaited<ReturnType<typeof commands.updateSetIgnored>>,
    ) => void;
    vi.mocked(commands.updateSetIgnored).mockReturnValue(
      new Promise((resolve) => {
        resolveMute = resolve;
      }),
    );
    const muting = useUpdatesStore.getState().setIgnored(row({}), true);

    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    await useUpdatesStore.getState().updateOne(row({ pinned: true }));

    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(commands.packageUpdate).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.message).toBe(
      UPDATE_NEEDS_CHECK_NOTE,
    );

    const muted = [row({ ignored: true })];
    resolveMute({
      status: "ok",
      data: { rows: muted, warnings: [], lastFetched: null },
    });
    await muting;
    expect(useUpdatesStore.getState().rows).toEqual(muted);
  });

  // The same for a plain read: a focus-triggered load leaves loaded true
  // and never sets checking, but its landing is about to replace the rows
  // an update would capture its commit from.
  it("refuses an update while a focus load is in flight", async () => {
    let resolveLoad!: (
      value: Awaited<ReturnType<typeof commands.updatesOverview>>,
    ) => void;
    vi.mocked(commands.updatesOverview).mockReturnValue(
      new Promise((resolve) => {
        resolveLoad = resolve;
      }),
    );
    const loading = useUpdatesStore.getState().load();

    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    await useUpdatesStore.getState().updateOne(row({ pinned: true }));

    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(commands.packageUpdate).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.message).toBe(
      UPDATE_NEEDS_CHECK_NOTE,
    );

    resolveLoad({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });
    await loading;
    expect(commands.packageSetRev).not.toHaveBeenCalled();
  });

  // An explicit check that failed is an answer to report: a quicker plain
  // load landing in between must not bury it and leave stale rows marked
  // current.
  it("a slow check's failure still reports after a later-started load", async () => {
    let rejectCheck!: (reason: Error) => void;
    vi.mocked(commands.updatesRefresh).mockReturnValue(
      new Promise((_, reject) => {
        rejectCheck = reject;
      }),
    );
    const checking = useUpdatesStore.getState().check();

    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [row({})], warnings: [], lastFetched: null },
    });
    await useUpdatesStore.getState().load();

    rejectCheck(new Error("mirror down"));
    await checking;

    expect(useUpdatesStore.getState().loaded).toBe(false);
    expect(useUpdatesStore.getState().error).toBe("mirror down");
  });

  // A failed mute may still have committed before erroring, so the store
  // re-reads rather than trusting either story: here the truth confirms
  // the kept rows, and nothing is marked stale.
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
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: kept, warnings: [], lastFetched: null },
    });

    await useUpdatesStore.getState().setIgnored(row({}), true);

    expect(useUpdatesStore.getState().rows).toEqual(kept);
    expect(useUpdatesStore.getState().loaded).toBe(true);
    expect(useUpdatesStore.getState().error).toBeNull();
    // The refusal still reaches the person, through the error modal.
    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe("manifest busy");
  });

  // A transport failure rejects instead of returning an error result —
  // only the applier sees it, and dropping its return left updateOne
  // silent and setAutoUpdate mute about a switch that never happened.
  it("surfaces an update whose transport failed instead of staying silent", async () => {
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.packageUpdate).mockRejectedValue(new Error("ipc down"));
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });

    await useUpdatesStore.getState().updateOne(row({}));

    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe("ipc down");
    expect(toast.success).not.toHaveBeenCalled();
  });

  it("surfaces a follow switch whose transport failed", async () => {
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.packageSetRev).mockRejectedValue(new Error("ipc down"));
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });

    await useUpdatesStore.getState().setAutoUpdate(row({}), false);

    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe("ipc down");
  });

  // A check in flight is about to replace the rows: an update accepted
  // now would queue behind it on the chain and apply the latest captured
  // before it — refused at the action boundary, not just on the buttons.
  it("refuses an update clicked while a check is running", async () => {
    let resolveCheck!: (
      value: Awaited<ReturnType<typeof commands.updatesRefresh>>,
    ) => void;
    vi.mocked(commands.updatesRefresh).mockReturnValue(
      new Promise((resolve) => {
        resolveCheck = resolve;
      }),
    );
    const checking = useUpdatesStore.getState().check();

    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    await useUpdatesStore.getState().updateOne(row({ pinned: true }));

    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(commands.packageUpdate).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.message).toBe(
      UPDATE_NEEDS_CHECK_NOTE,
    );

    resolveCheck({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });
    await checking;
    expect(commands.packageSetRev).not.toHaveBeenCalled();
  });

  // An update that commits, fails its first overview read, and reconciles
  // is a success: the rows land current, and reporting the dead first
  // read as the update's failure would suppress the toast and skip the
  // scan and audit refreshes over a change that landed.
  it("an update whose first re-read fails but reconciles reports success", async () => {
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.packageUpdate).mockResolvedValue({
      status: "ok",
      data: {
        view: {
          scope: { scope: "global" },
          drift: [],
          plan: [],
          notes: [],
          warnings: [],
          safety: [],
          adoptable: ADOPTABLE,
          exits: [],
        },
        heldBack: [],
        removed: [],
        moved: [],
      },
    });
    const landed = [row({ updateAvailable: false })];
    vi.mocked(commands.updatesOverview)
      .mockRejectedValueOnce(new Error("overview wedged"))
      .mockResolvedValueOnce({
        status: "ok",
        data: { rows: landed, warnings: [], lastFetched: null },
      });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await useUpdatesStore.getState().updateOne(row({}));

    expect(useProblemsStore.getState().dialog.open).toBe(false);
    expect(toast.success).toHaveBeenCalled();
    expect(commands.scanMachine).toHaveBeenCalled();
    expect(commands.auditAll).toHaveBeenCalled();
    expect(useUpdatesStore.getState().rows).toEqual(landed);
    expect(useUpdatesStore.getState().loaded).toBe(true);
    expect(useUpdatesStore.getState().error).toBeNull();
  });

  // The backend can persist the preference and then fail building its
  // overview: the reconciling read lands what actually committed instead
  // of leaving the old row marked current.
  it("a mute that commits but errors re-reads the truth", async () => {
    useUpdatesStore.setState({ rows: [row({})], loaded: true, error: null });
    vi.mocked(commands.updateSetIgnored).mockResolvedValue({
      status: "error",
      error: "couldn't rebuild the overview",
    });
    const muted = [row({ ignored: true })];
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: muted, warnings: [], lastFetched: null },
    });

    await useUpdatesStore.getState().setIgnored(row({}), true);

    expect(useUpdatesStore.getState().rows).toEqual(muted);
    expect(useUpdatesStore.getState().loaded).toBe(true);
  });

  it("marks the rows stale when the reconciling read also fails", async () => {
    const kept = [row({})];
    useUpdatesStore.setState({ rows: kept, loaded: true, error: null });
    vi.mocked(commands.updateSetIgnored).mockResolvedValue({
      status: "error",
      error: "half done",
    });
    vi.mocked(commands.updatesOverview).mockRejectedValue(
      new Error("ipc down"),
    );

    await useUpdatesStore.getState().setIgnored(row({}), true);

    expect(useUpdatesStore.getState().rows).toEqual(kept);
    expect(useUpdatesStore.getState().loaded).toBe(false);
    expect(useUpdatesStore.getState().error).toBe("half done");
  });

  it("muting keeps the row, flagged — and unmuting brings it back", async () => {
    const muted = [row({ ignored: true })];
    vi.mocked(commands.updateSetIgnored).mockResolvedValue({
      status: "ok",
      data: { rows: muted, warnings: [], lastFetched: null },
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
        view: {
          scope: { scope: "global" },
          drift: [],
          plan: [],
          notes: [],
          warnings: [],
          safety: [],
          adoptable: ADOPTABLE,
          exits: [],
        },
        heldBack: [],
        removed: [],
        moved: [],
      },
    });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
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
    expect(commands.packageUpdate).not.toHaveBeenCalled();
  });

  it("updating a following package applies just that package", async () => {
    vi.mocked(commands.packageUpdate).mockResolvedValue({
      status: "ok",
      data: {
        view: {
          scope: { scope: "global" },
          drift: [],
          plan: [],
          notes: [],
          warnings: [],
          safety: [],
          adoptable: ADOPTABLE,
          exits: [],
        },
        heldBack: [],
        removed: [],
        moved: [],
      },
    });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], lastFetched: null },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await useUpdatesStore.getState().updateOne(row({}));

    expect(commands.packageUpdate).toHaveBeenCalledWith(
      { scope: "global" },
      "skill",
      "gh",
    );
    expect(commands.packageSetRev).not.toHaveBeenCalled();
  });
});
