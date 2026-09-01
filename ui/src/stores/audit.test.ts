import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "./audit";
import { useProblemsStore } from "./problems";

vi.mock("@/bindings", () => ({
  commands: {
    auditAll: vi.fn(),
    adoptItem: vi.fn(),
    toggleItem: vi.fn(),
    removeItem: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn(), message: vi.fn() },
}));

vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));

const globalScope = { scope: "global" as const };

const emptyView: AuditView = {
  scope: globalScope,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
};

describe("audit store refresh", () => {
  beforeEach(() => {
    useAuditStore.setState({
      views: [],
      auditing: false,
      error: null,
      read: READ_LANDED,
      busy: false,
      auditedAt: null,
      backgroundFailureAnnounced: false,
    });
    vi.clearAllMocks();
  });

  it("toasts a background audit failure once, not on every silent retry", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "error",
      error: "boom",
    });

    await useAuditStore.getState().refresh();
    await useAuditStore.getState().refresh();

    expect(toast.error).toHaveBeenCalledTimes(1);
  });

  // A rejected call used to escape the store: auditedAt stayed null with
  // no error, which Home read as an audit still on its way — forever.
  it("lands a rejected call as a failed audit", async () => {
    vi.mocked(commands.auditAll).mockRejectedValue(new Error("ipc down"));

    await useAuditStore.getState().refresh();

    expect(useAuditStore.getState().error).toBe("ipc down");
    expect(useAuditStore.getState().read.error).toBe("ipc down");
    expect(useAuditStore.getState().auditing).toBe(false);
  });

  it("clears the read failure once an audit answers again", async () => {
    vi.mocked(commands.auditAll).mockResolvedValueOnce({
      status: "error",
      error: "boom",
    });
    await useAuditStore.getState().refresh();
    expect(useAuditStore.getState().read.error).toBe("boom");

    vi.mocked(commands.auditAll).mockResolvedValueOnce({
      status: "ok",
      data: [],
    });
    await useAuditStore.getState().refresh({ force: true });
    expect(useAuditStore.getState().read.error).toBeNull();
  });

  it("re-arms the toast after a successful audit", async () => {
    vi.mocked(commands.auditAll).mockResolvedValueOnce({
      status: "error",
      error: "boom",
    });
    await useAuditStore.getState().refresh();

    vi.mocked(commands.auditAll).mockResolvedValueOnce({
      status: "ok",
      data: [],
    });
    await useAuditStore.getState().refresh();

    vi.mocked(commands.auditAll).mockResolvedValueOnce({
      status: "error",
      error: "boom again",
    });
    await useAuditStore.getState().refresh({ force: true });

    expect(toast.error).toHaveBeenCalledTimes(2);
  });

  it("reuses a recent audit instead of re-running it on every visit", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await useAuditStore.getState().refresh();
    await useAuditStore.getState().refresh();

    expect(commands.auditAll).toHaveBeenCalledTimes(1);
  });

  it("re-runs an audit the caller asks for by name", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await useAuditStore.getState().refresh();
    await useAuditStore.getState().refresh({ force: true });

    expect(commands.auditAll).toHaveBeenCalledTimes(2);
  });

  // A force says the bytes changed. Dropping it because a machine-wide read
  // happened to be running left every score on screen answering for the
  // state before whatever prompted it — and the earlier guard dropped it on
  // the `auditing` flag, which a caller can leave standing.
  //
  // Each call parks until the test lets it go, which is the only way to have
  // a request arrive while an audit is genuinely in flight.
  const parkAudits = () => {
    const waiting: (() => void)[] = [];
    vi.mocked(commands.auditAll).mockImplementation(
      () =>
        new Promise((resolve) => {
          waiting.push(() => resolve({ status: "ok", data: [] }));
        }) as ReturnType<typeof commands.auditAll>,
    );
    return () => {
      for (const land of waiting.splice(0)) land();
    };
  };

  it("runs a forced refresh that arrives while an audit is in flight", async () => {
    const land = parkAudits();

    const first = useAuditStore.getState().refresh();
    const queued = useAuditStore.getState().refresh({ force: true });
    expect(commands.auditAll).toHaveBeenCalledTimes(1);

    land();
    await first;
    // The follow-up starts as the first audit lands, so its call is only
    // on the record once that has happened.
    expect(commands.auditAll).toHaveBeenCalledTimes(2);
    land();
    await queued;
  });

  it("queues one follow-up however many forces arrive mid-audit", async () => {
    const land = parkAudits();

    const first = useAuditStore.getState().refresh();
    const forces = [
      useAuditStore.getState().refresh({ force: true }),
      useAuditStore.getState().refresh({ force: true }),
      useAuditStore.getState().refresh({ force: true }),
    ];

    land();
    await first;
    land();
    await Promise.all(forces);

    expect(commands.auditAll).toHaveBeenCalledTimes(2);
  });

  // An unforced visit while an audit runs waits on that audit rather than
  // starting a second machine-wide read of the same files.
  it("does not start a second audit for an unforced visit mid-audit", async () => {
    const land = parkAudits();

    const first = useAuditStore.getState().refresh();
    const visit = useAuditStore.getState().refresh();

    land();
    await Promise.all([first, visit]);

    expect(commands.auditAll).toHaveBeenCalledTimes(1);
  });

  // The flag says what to draw. A caller that left it standing — a test
  // staging state, a render mid-update — must not silence the next audit.
  it("does not let a stale auditing flag swallow a forced refresh", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
    useAuditStore.setState({ auditing: true });

    await useAuditStore.getState().refresh({ force: true });

    expect(commands.auditAll).toHaveBeenCalledTimes(1);
  });

  it("does not toast on a successful audit", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [],
    });

    await useAuditStore.getState().refresh();

    expect(toast.error).not.toHaveBeenCalled();
  });
});

describe("audit store run() actions", () => {
  beforeEach(() => {
    useAuditStore.setState({
      views: [emptyView],
      auditing: false,
      error: null,
      read: READ_LANDED,
      busy: false,
      auditedAt: null,
      backgroundFailureAnnounced: false,
    });
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.clearAllMocks();
  });

  it("shows the error modal with the backend message on a failed action, not silently", async () => {
    vi.mocked(commands.removeItem).mockResolvedValue({
      status: "error",
      error: "disk is full",
    });

    await useAuditStore.getState().removeItem(globalScope, "hook", "lint");

    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe("Couldn't remove lint");
    expect(dialog.message).toBe("disk is full");
    expect(useAuditStore.getState().error).toBe("disk is full");
    // A failed item action is not a failed audit: only refresh may write
    // the signal Home's couldn't-check row reads.
    expect(useAuditStore.getState().read.error).toBeNull();
    expect(toast.error).not.toHaveBeenCalled();
  });

  it("shows the error modal with the backend message on an adopt failure", async () => {
    vi.mocked(commands.adoptItem).mockResolvedValue({
      status: "error",
      error: "permission denied",
    });

    await useAuditStore
      .getState()
      .adopt(globalScope, "hook", "lint", ["claude"]);

    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe("Couldn't start managing lint");
    expect(dialog.message).toBe("permission denied");
    expect(toast.success).not.toHaveBeenCalled();
  });

  it("toasts a success message when adopting an item", async () => {
    vi.mocked(commands.adoptItem).mockResolvedValue({
      status: "ok",
      data: emptyView,
    });

    await useAuditStore
      .getState()
      .adopt(globalScope, "hook", "lint", ["claude"]);

    expect(toast.success).toHaveBeenCalledWith("Now managing lint");
    expect(toast.error).not.toHaveBeenCalled();
  });

  it("does not toast success for a silent action like a toggle", async () => {
    vi.mocked(commands.toggleItem).mockResolvedValue({
      status: "ok",
      data: emptyView,
    });

    await useAuditStore.getState().toggle(globalScope, "hook", "lint", false);

    expect(toast.success).not.toHaveBeenCalled();
  });

  // Removing a package that armed the repository runs its uninstaller
  // first, and what ran is the removal's own account — a removal that
  // said nothing left people hunting for shims under `.git/hooks`.
  it("says what the removal ran in the repository", async () => {
    vi.mocked(commands.removeItem).mockResolvedValue({
      status: "ok",
      data: {
        ...emptyView,
        undone: [
          "growth-guards: running scripts/install-git-hooks --uninstall",
        ],
      },
    });

    await useAuditStore.getState().removeItem(globalScope, "skill", "guards");

    expect(toast.message).toHaveBeenCalledWith(
      "growth-guards: running scripts/install-git-hooks --uninstall",
    );
  });

  it("stays quiet when the removal had no repository effect to undo", async () => {
    vi.mocked(commands.removeItem).mockResolvedValue({
      status: "ok",
      data: emptyView,
    });

    await useAuditStore.getState().removeItem(globalScope, "skill", "deploy");

    expect(toast.message).not.toHaveBeenCalled();
  });

  it("a refused action surfaces as an error, never a silent success", async () => {
    vi.mocked(commands.toggleItem).mockResolvedValue({
      status: "error",
      error: "'scraper' changed since the plan was read",
    });

    await useAuditStore.getState().toggle(globalScope, "hook", "lint", false);

    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toContain(
      "changed since",
    );
    expect(toast.success).not.toHaveBeenCalled();
  });
});

// An audit reads every scope over seconds while the page it started from
// leaves its buttons live. A command that lands in between read its scope
// later, so the audit's answer is already out of date when it arrives.
describe("an audit that lands after a command it cannot answer for", () => {
  const settled: AuditView = { ...emptyView, drift: [], plan: ["settled"] };
  const stale: AuditView = { ...emptyView, drift: [], plan: ["stale"] };

  beforeEach(() => {
    useAuditStore.setState({
      // A view to replace: a command's response lands into the scope it
      // already holds.
      views: [emptyView],
      auditing: false,
      error: null,
      read: READ_LANDED,
      busy: false,
      auditedAt: null,
      backgroundFailureAnnounced: false,
    });
    vi.clearAllMocks();
  });

  const park = <T>() => {
    let land: (value: T) => void = () => {};
    const parked = new Promise<T>((resolve) => {
      land = resolve;
    });
    return { parked, land: (value: T) => land(value) };
  };

  it("keeps the command's view rather than putting the row back", async () => {
    const audit = park<{ status: "ok"; data: AuditView[] }>();
    vi.mocked(commands.auditAll).mockReturnValue(
      audit.parked as ReturnType<typeof commands.auditAll>,
    );
    vi.mocked(commands.removeItem).mockResolvedValue({
      status: "ok",
      data: settled,
    });

    const running = useAuditStore.getState().refresh();
    await useAuditStore.getState().removeItem(globalScope, "hook", "lint");
    audit.land({ status: "ok", data: [stale] });
    await running;

    expect(useAuditStore.getState().views).toEqual([settled]);
    // Undated, so the next visit pays for a reading that can speak for
    // what just happened instead of reusing one that cannot.
    expect(useAuditStore.getState().auditedAt).toBeNull();
  });

  // The two orderings the pair of marks exists for, each reachable on its
  // own. An attempt is a span, not a moment: a command writes throughout
  // its own run, so a reading that overlaps either end of that span is out
  // of date. Awaiting the command to completion inside the audit puts its
  // whole span under both marks at once, which is why the cases below park
  // one side or the other.

  // The audit lands while the command is still out: only the mark at the
  // START of the attempt has fired, and it is what says this reading
  // cannot answer.
  it("drops a reading that landed while an attempt was still running", async () => {
    const audit = park<{ status: "ok"; data: AuditView[] }>();
    const command = park<{ status: "ok"; data: AuditView }>();
    vi.mocked(commands.auditAll).mockReturnValue(
      audit.parked as ReturnType<typeof commands.auditAll>,
    );
    vi.mocked(commands.removeItem).mockReturnValue(
      command.parked as ReturnType<typeof commands.removeItem>,
    );

    const running = useAuditStore.getState().refresh();
    const acting = useAuditStore
      .getState()
      .removeItem(globalScope, "hook", "lint");
    audit.land({ status: "ok", data: [stale] });
    await running;

    expect(useAuditStore.getState().views).toEqual([emptyView]);
    expect(useAuditStore.getState().auditedAt).toBeNull();

    command.land({ status: "ok", data: settled });
    await acting;
  });

  // The mirror: the command's start mark has already fired when the audit
  // begins, so that one cannot tell this reading apart. Only the mark at
  // the END of the attempt moves the counter under it.
  it("drops a reading an attempt finished under", async () => {
    const audit = park<{ status: "ok"; data: AuditView[] }>();
    const command = park<{ status: "ok"; data: AuditView }>();
    vi.mocked(commands.removeItem).mockReturnValue(
      command.parked as ReturnType<typeof commands.removeItem>,
    );
    const acting = useAuditStore
      .getState()
      .removeItem(globalScope, "hook", "lint");
    // The attempt is under way before the audit is asked for.
    await Promise.resolve();

    vi.mocked(commands.auditAll).mockReturnValue(
      audit.parked as ReturnType<typeof commands.auditAll>,
    );
    const running = useAuditStore.getState().refresh();

    command.land({ status: "ok", data: settled });
    await acting;
    audit.land({ status: "ok", data: [stale] });
    await running;

    // The command's own view stands, undated so the next visit pays for a
    // reading that can speak for what it did.
    expect(useAuditStore.getState().views).toEqual([settled]);
    expect(useAuditStore.getState().auditedAt).toBeNull();
  });

  // Dropping the read is only half of it. The command installed its own
  // scope and nothing re-read the rest, so a stamp left standing would hold
  // the freshness window open over the very bytes the force was about — an
  // editor save, say, with every score still quoting the state before it.
  it("pays for the read it dropped instead of reusing the stamp", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [stale],
    });
    await useAuditStore.getState().refresh();
    expect(useAuditStore.getState().auditedAt).not.toBeNull();

    const audit = park<{ status: "ok"; data: AuditView[] }>();
    vi.mocked(commands.auditAll).mockReturnValue(
      audit.parked as ReturnType<typeof commands.auditAll>,
    );
    vi.mocked(commands.removeItem).mockResolvedValue({
      status: "ok",
      data: settled,
    });
    const forced = useAuditStore.getState().refresh({ force: true });
    await useAuditStore.getState().removeItem(globalScope, "hook", "lint");
    audit.land({ status: "ok", data: [stale] });
    await forced;

    const dropped = vi.mocked(commands.auditAll).mock.calls.length;
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [settled],
    });
    // An ordinary visit, not another force: the window must not answer it.
    await useAuditStore.getState().refresh();

    expect(vi.mocked(commands.auditAll).mock.calls.length).toBe(dropped + 1);
  });
});
