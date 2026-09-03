import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { UpdateRow } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { UPDATE_NEEDS_CHECK_NOTE } from "@/lib/copy-updates";
import { READ_LANDED } from "@/lib/read-state";
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
    packageUpdateMany: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    libraryProvenance: vi.fn().mockResolvedValue({ status: "ok", data: [] }),
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
    requiredBy: [],
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
      warnings: [],
      unreadable: [],
      busy: false,
      checking: false,
      pendingFollows: [],
      read: READ_LANDED,
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
      data: {
        rows: [row({})],
        warnings: [],
        unreadable: [],
        lastFetched: CHECKED_AT,
      },
    });
    await useUpdatesStore.getState().reload();
    expect(useUpdatesStore.getState().lastFetched).toBe(CHECKED_AT);
  });

  // The refresh lands on the side-effect chain rather than the plain-read
  // path, so it carries the age through different code.
  it("lands the age a check reports", async () => {
    vi.mocked(commands.updatesRefresh).mockResolvedValue({
      status: "ok",
      data: {
        rows: [row({})],
        warnings: [],
        unreadable: [],
        lastFetched: CHECKED_AT,
      },
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

  // A failed read used to leave only a not-landed flag behind —
  // indistinguishable from a read still on its way, so Home and the badge
  // had nothing to show for it.
  it("keeps why a read failed, and a good read clears it", async () => {
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "error",
      error: "no network",
    });
    await useUpdatesStore.getState().reload();
    expect(useUpdatesStore.getState().read.error).toBe("no network");
    expect(useUpdatesStore.getState().read.status).toBe("failed");

    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });
    await useUpdatesStore.getState().reload();
    expect(useUpdatesStore.getState().read.error).toBeNull();
    expect(useUpdatesStore.getState().read.status).toBe("landed");
  });

  // A rejected call used to escape the store entirely — no error recorded,
  // the promise discarded by its callers — while a returned refusal landed.
  it("lands a rejected read the same as a returned refusal", async () => {
    const kept = [row({})];
    useUpdatesStore.setState({ rows: kept, read: READ_LANDED });
    vi.mocked(commands.updatesOverview).mockRejectedValue(
      new Error("ipc down"),
    );

    await useUpdatesStore.getState().reload();

    expect(useUpdatesStore.getState().read.error).toBe("ipc down");
    expect(useUpdatesStore.getState().read.status).toBe("failed");
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
    expect(useUpdatesStore.getState().read.error).toBe("mirror down");
    expect(useUpdatesStore.getState().read.status).toBe("failed");
    expect(useUpdatesStore.getState().checking).toBe(false);

    vi.mocked(commands.updatesRefresh).mockRejectedValue(new Error("ipc"));
    await useUpdatesStore.getState().check();
    expect(useUpdatesStore.getState().read.error).toBe("ipc");
    expect(useUpdatesStore.getState().checking).toBe(false);
  });

  it("ignores a check clicked while one is already running", async () => {
    useUpdatesStore.setState({ checking: true });
    await useUpdatesStore.getState().check();
    expect(commands.updatesRefresh).not.toHaveBeenCalled();
    useUpdatesStore.setState({ checking: false });
  });

  // Reads land in any order, and they overlap on every ordinary path: the
  // startup effect against the page's own mount, the focus rescan against
  // both. Without ordering a slow early one landing last overwrites a
  // fresher answer and stamps its stale rows current.
  it("discards a slow load that lands after a fresher check", async () => {
    let resolveLoad!: (
      value: Awaited<ReturnType<typeof commands.updatesOverview>>,
    ) => void;
    vi.mocked(commands.updatesOverview).mockReturnValue(
      new Promise((resolve) => {
        resolveLoad = resolve;
      }),
    );
    const loading = useUpdatesStore.getState().reload();

    const fresh = [row({ name: "fresh" })];
    vi.mocked(commands.updatesRefresh).mockResolvedValue({
      status: "ok",
      data: { rows: fresh, warnings: [], unreadable: [], lastFetched: null },
    });
    await useUpdatesStore.getState().check();

    resolveLoad({
      status: "ok",
      data: {
        rows: [row({ name: "stale" })],
        warnings: [],
        unreadable: [],
        lastFetched: null,
      },
    });
    await loading;

    expect(useUpdatesStore.getState().rows).toEqual(fresh);
    expect(useUpdatesStore.getState().read.status).toBe("landed");
  });

  // The whole read state rides on the ordering, not just the rows: an
  // older landing that cleared a newer failure would take the unconfirmed
  // banner off the page and re-enable every write it holds back.
  it("discards a slow failed load landing after a fresher answer", async () => {
    let rejectLoad!: (reason: Error) => void;
    vi.mocked(commands.updatesOverview).mockReturnValue(
      new Promise((_, reject) => {
        rejectLoad = reject;
      }),
    );
    const loading = useUpdatesStore.getState().reload();

    vi.mocked(commands.updatesRefresh).mockResolvedValue({
      status: "ok",
      data: {
        rows: [row({})],
        warnings: [],
        unreadable: [],
        lastFetched: null,
      },
    });
    await useUpdatesStore.getState().check();

    rejectLoad(new Error("ipc down"));
    await loading;

    expect(useUpdatesStore.getState().read.status).toBe("landed");
    expect(useUpdatesStore.getState().read.error).toBeNull();
  });

  // A mount or a return to the window reloads over rows that landed
  // perfectly well. The read state stays `landed` throughout — the rows
  // are still the last answer — so nothing in it says the values under
  // the buttons are about to be replaced. An update accepted in that
  // window commits a `latest.commit` the landing is about to change.
  it("refuses an update while an ordinary reload is in flight", async () => {
    let landRead!: (
      value: Awaited<ReturnType<typeof commands.updatesOverview>>,
    ) => void;
    vi.mocked(commands.updatesOverview)
      .mockReturnValueOnce(
        new Promise((resolve) => {
          landRead = resolve;
        }),
      )
      // Anything the refusal is supposed to prevent would re-read behind
      // its own commit; answering that keeps a broken guard failing on the
      // assertion rather than hanging on a parked promise.
      .mockResolvedValue({
        status: "ok",
        data: {
          rows: [row({})],
          warnings: [],
          unreadable: [],
          lastFetched: null,
        },
      });
    useUpdatesStore.setState({ rows: [row({})], read: READ_LANDED });
    const reloading = useUpdatesStore.getState().reload();

    // The rows are still the last landed answer, which is exactly the
    // state that used to let this through.
    expect(useUpdatesStore.getState().read.status).toBe("landed");
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });

    await useUpdatesStore.getState().updateOne(row({ pinned: true }));

    expect(commands.packageSetRev).not.toHaveBeenCalled();
    expect(commands.packageUpdate).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.message).toBe(
      UPDATE_NEEDS_CHECK_NOTE,
    );

    // And the bar lifts with the landing, rather than outliving it.
    landRead({
      status: "ok",
      data: {
        rows: [row({})],
        warnings: [],
        unreadable: [],
        lastFetched: null,
      },
    });
    await reloading;
    expect(useUpdatesStore.getState().reading).toBe(false);
  });

  // The control for the exclusion in `updates-exclusion.test.ts`: with
  // nothing committing meanwhile, a check still outranks every read out.
  // That landing-time rank is what the exclusion protects, and what
  // refusing writes beside a check must not take away.
  it("still outranks a read that was out when the check answers", async () => {
    let landRead!: (
      value: Awaited<ReturnType<typeof commands.updatesOverview>>,
    ) => void;
    vi.mocked(commands.updatesOverview).mockReturnValue(
      new Promise((resolve) => {
        landRead = resolve;
      }),
    );
    const reloading = useUpdatesStore.getState().reload();

    const fresh = [row({ name: "fresh" })];
    vi.mocked(commands.updatesRefresh).mockResolvedValue({
      status: "ok",
      data: { rows: fresh, warnings: [], unreadable: [], lastFetched: null },
    });
    await useUpdatesStore.getState().check();
    expect(useUpdatesStore.getState().rows).toEqual(fresh);

    landRead({
      status: "ok",
      data: {
        rows: [row({ name: "stale" })],
        warnings: [],
        unreadable: [],
        lastFetched: null,
      },
    });
    await reloading;

    expect(useUpdatesStore.getState().rows).toEqual(fresh);
  });

  // A failed mute may still have committed before erroring, so the store
  // re-reads rather than trusting either story: here the truth confirms
  // the kept rows, and nothing is marked stale.
  it("a mute that fails leaves the last good read trusted", async () => {
    const kept = [row({})];
    useUpdatesStore.setState({ rows: kept, read: READ_LANDED });
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.updateSetIgnored).mockResolvedValue({
      status: "error",
      error: "manifest busy",
    });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: kept, warnings: [], unreadable: [], lastFetched: null },
    });

    await useUpdatesStore.getState().setIgnored(row({}), true);

    expect(useUpdatesStore.getState().rows).toEqual(kept);
    expect(useUpdatesStore.getState().read.status).toBe("landed");
    expect(useUpdatesStore.getState().read.error).toBeNull();
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
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });

    await useUpdatesStore.getState().updateOne(row({}));

    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toBe("ipc down");
    expect(toast.success).not.toHaveBeenCalled();
    // The rejection arm reads the machine too, and it is the arm that
    // accounts for least: the call never answered, so nothing says whether
    // the apply ran. Left unstubbed, the scan and the audit land as failed
    // reads, which is all this pins — that they were asked.
    expect(commands.scanMachine).toHaveBeenCalled();
    expect(commands.auditAll).toHaveBeenCalled();
  });

  it("surfaces a follow switch whose transport failed", async () => {
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.packageSetRev).mockRejectedValue(new Error("ipc down"));
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
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
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });
    await checking;
    expect(commands.packageSetRev).not.toHaveBeenCalled();
  });

  // An update that commits and then cannot be read back is still a
  // success: reporting the dead read as the update's failure would
  // suppress the toast and skip the scan and audit refreshes over a change
  // that landed. The rows say they are last-known, which is the truth.
  it("reports an update that committed even when the read behind it fails", async () => {
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
    const kept = [row({})];
    useUpdatesStore.setState({ rows: kept, read: READ_LANDED });
    vi.mocked(commands.updatesOverview).mockRejectedValue(
      new Error("overview wedged"),
    );
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
    // Nothing confirmed the rows, so they stay and say so.
    expect(useUpdatesStore.getState().rows).toEqual(kept);
    expect(useUpdatesStore.getState().read.status).toBe("failed");
    expect(useUpdatesStore.getState().read.error).toBe("overview wedged");
  });

  /** The three reads a write's follow-up makes, all answering. */
  const machineAnswers = () => {
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });
  };

  // The machine reads are owed whichever way the apply answered, on
  // `lib/rescan.ts`'s rule. Gated on the answer, Home's inventory and the
  // audit scores went on reporting copies already taken off disk until
  // something else forced a read. Both arms of the choice `applyRow` makes
  // between the two single-package commands, since a held row moves its
  // hold through the other one.
  it.each([
    ["a follower", row({}), commands.packageUpdate, "the apply stopped"],
    [
      "a held row",
      row({ pinned: true }),
      commands.packageSetRev,
      "manifest busy",
    ],
  ])(
    "reads the machine back when %s answers with an error",
    async (_what, subject, command, error) => {
      useProblemsStore.setState({
        dialog: { open: false, title: "", steps: [], actions: [] },
      });
      machineAnswers();
      vi.mocked(command).mockResolvedValue({ status: "error", error } as never);
      useUpdatesStore.setState({ rows: [subject], read: READ_LANDED });

      await useUpdatesStore.getState().updateOne(subject);

      expect(command).toHaveBeenCalled();
      expect(commands.scanMachine).toHaveBeenCalled();
      expect(commands.auditAll).toHaveBeenCalled();
      // The refusal is still the person's to see, and nothing claims a move.
      expect(useProblemsStore.getState().dialog.message).toBe(error);
      expect(toast.success).not.toHaveBeenCalled();
    },
  );

  // The backend can persist the preference and then fail building its
  // overview: the reconciling read lands what actually committed instead
  // of leaving the old row marked current.
  it("a mute that commits but errors re-reads the truth", async () => {
    useUpdatesStore.setState({ rows: [row({})], read: READ_LANDED });
    vi.mocked(commands.updateSetIgnored).mockResolvedValue({
      status: "error",
      error: "couldn't rebuild the overview",
    });
    const muted = [row({ ignored: true })];
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: muted, warnings: [], unreadable: [], lastFetched: null },
    });

    await useUpdatesStore.getState().setIgnored(row({}), true);

    expect(useUpdatesStore.getState().rows).toEqual(muted);
    expect(useUpdatesStore.getState().read.status).toBe("landed");
  });

  it("marks the rows stale when the reconciling read also fails", async () => {
    const kept = [row({})];
    useUpdatesStore.setState({ rows: kept, read: READ_LANDED });
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.mocked(commands.updateSetIgnored).mockResolvedValue({
      status: "error",
      error: "half done",
    });
    vi.mocked(commands.updatesOverview).mockRejectedValue(
      new Error("ipc down"),
    );

    await useUpdatesStore.getState().setIgnored(row({}), true);

    expect(useUpdatesStore.getState().rows).toEqual(kept);
    expect(useUpdatesStore.getState().read.status).toBe("failed");
    // The read says why nothing confirmed these rows; the refusal that
    // sent it is the person's own news, in the dialog.
    expect(useUpdatesStore.getState().read.error).toBe("ipc down");
    expect(useProblemsStore.getState().dialog.message).toBe("half done");
  });

  it("muting keeps the row, flagged — and unmuting brings it back", async () => {
    const muted = [row({ ignored: true })];
    vi.mocked(commands.updateSetIgnored).mockResolvedValue({
      status: "ok",
      data: { rows: muted, warnings: [], unreadable: [], lastFetched: null },
    });
    // The mute reads the standing back rather than trusting its own
    // report, so this is what lands.
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: muted, warnings: [], unreadable: [], lastFetched: null },
    });
    useUpdatesStore.setState({ rows: [row({})], read: READ_LANDED });

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
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
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
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
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
