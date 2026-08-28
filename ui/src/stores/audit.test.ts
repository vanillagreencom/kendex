import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
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
  toast: { error: vi.fn(), success: vi.fn() },
}));

vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));

const globalScope = { scope: "global" as const };
const acme = { scope: "project" as const, root: "/work/acme" };

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
      checkError: null,
      busy: false,
      auditedAt: null,
      scopeCheckedAt: {},
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
    expect(useAuditStore.getState().checkError).toBe("ipc down");
    expect(useAuditStore.getState().auditing).toBe(false);
  });

  it("clears checkError once an audit answers again", async () => {
    vi.mocked(commands.auditAll).mockResolvedValueOnce({
      status: "error",
      error: "boom",
    });
    await useAuditStore.getState().refresh();
    expect(useAuditStore.getState().checkError).toBe("boom");

    vi.mocked(commands.auditAll).mockResolvedValueOnce({
      status: "ok",
      data: [],
    });
    await useAuditStore.getState().refresh({ force: true });
    expect(useAuditStore.getState().checkError).toBeNull();
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

// auditAll answers ok for the machine while carrying a per-scope failure:
// one scope's lock is corrupt, or its manifest came from a newer kendex.
// That view arrives empty, and taking it whole replaces a real reading with
// zeros and reports them as this moment's answer.
describe("an audit that could not read one scope", () => {
  const scored = (scope: typeof globalScope | typeof acme): AuditView => ({
    ...emptyView,
    scope,
    safety: [
      {
        kind: "skill",
        name: "gh",
        harness: "claude",
        scope,
        location: "",
        findings: [],
        skipped: [],
        safety: { score: 91, deductions: [] },
        quality: null,
        ruleset: 3,
      },
    ],
  });
  const unreadable = (scope: typeof acme): AuditView => ({
    ...emptyView,
    scope,
    error: { kind: "lock-corrupt", message: "lock is not JSON" },
  });

  beforeEach(() => {
    useAuditStore.setState({
      views: [scored(globalScope), scored(acme)],
      auditing: false,
      error: null,
      checkError: null,
      busy: false,
      auditedAt: 1000,
      scopeCheckedAt: { global: 1000, "/work/acme": 1000 },
      backgroundFailureAnnounced: false,
    });
    vi.clearAllMocks();
  });

  it("keeps that scope's last reading rather than blanking it", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [scored(globalScope), unreadable(acme)],
    });

    await useAuditStore.getState().refresh({ force: true });

    const kept = useAuditStore
      .getState()
      .views.find((view) => view.scope.scope === "project");
    expect(kept?.safety).toHaveLength(1);
    // The failure rides on the kept view, so the Problems page still lists
    // it and the score surfaces can date the reading and offer the retry.
    expect(kept?.error?.message).toBe("lock is not JSON");
  });

  it("does not date the kept reading as if it had just been read", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [scored(globalScope), unreadable(acme)],
    });

    await useAuditStore.getState().refresh({ force: true });

    const stamps = useAuditStore.getState().scopeCheckedAt;
    expect(stamps["/work/acme"]).toBe(1000);
    expect(stamps.global).toBeGreaterThan(1000);
  });

  // A scope failing twice running must not lose on the second pass what it
  // kept on the first.
  it("keeps the reading through a second failure", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [scored(globalScope), unreadable(acme)],
    });

    await useAuditStore.getState().refresh({ force: true });
    await useAuditStore.getState().refresh({ force: true });

    expect(
      useAuditStore
        .getState()
        .views.find((view) => view.scope.scope === "project")?.safety,
    ).toHaveLength(1);
  });

  // The scores are all that carries over. Drift is a comparison against a
  // manifest this audit could not read, and the app adopts from those rows —
  // a write to the filesystem off a picture nothing has confirmed.
  it("keeps the scores and nothing else it could act on", async () => {
    const withDrift: AuditView = {
      ...scored(acme),
      drift: [
        {
          kind: "skill",
          name: "byhand",
          harness: "claude",
          state: "unmanaged",
          detail: "/work/acme/.claude/skills/byhand",
          scope: acme,
        },
      ],
      plan: ["install byhand"],
      notes: ["a note from before"],
    };
    useAuditStore.setState({ views: [withDrift] });
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [unreadable(acme)],
    });

    await useAuditStore.getState().refresh({ force: true });

    const kept = useAuditStore.getState().views[0];
    expect(kept?.safety).toHaveLength(1);
    expect(kept?.drift).toEqual([]);
    expect(kept?.plan).toEqual([]);
    expect(kept?.notes).toEqual([]);
  });

  it("lets a scope that answered keep its fresh reading", async () => {
    const fresh = scored(globalScope);
    fresh.safety[0].safety = { score: 40, deductions: [] };
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [fresh, unreadable(acme)],
    });

    await useAuditStore.getState().refresh({ force: true });

    expect(
      useAuditStore
        .getState()
        .views.find((view) => view.scope.scope === "global")?.safety[0]?.safety
        .score,
    ).toBe(40);
  });
});

describe("audit store run() actions", () => {
  beforeEach(() => {
    useAuditStore.setState({
      views: [emptyView],
      auditing: false,
      error: null,
      checkError: null,
      busy: false,
      auditedAt: null,
      scopeCheckedAt: {},
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
    expect(useAuditStore.getState().checkError).toBeNull();
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
      checkError: null,
      busy: false,
      auditedAt: null,
      scopeCheckedAt: {},
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

  // A read that did not finish is not news about the state it left behind
  // either: reported, it would mark a reading unconfirmed that a command
  // has since confirmed.
  it("drops a stale failure rather than calling the reading unchecked", async () => {
    const audit = park<{ status: "error"; error: string }>();
    vi.mocked(commands.auditAll).mockReturnValue(
      audit.parked as ReturnType<typeof commands.auditAll>,
    );
    vi.mocked(commands.removeItem).mockResolvedValue({
      status: "ok",
      data: settled,
    });

    const running = useAuditStore.getState().refresh();
    await useAuditStore.getState().removeItem(globalScope, "hook", "lint");
    audit.land({ status: "error", error: "boom" });
    await running;

    expect(useAuditStore.getState().checkError).toBeNull();
    expect(useAuditStore.getState().views).toEqual([settled]);
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

  // The control: an audit nothing overtook is the answer, as it was.
  it("installs an audit that no command overtook", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [stale],
    });

    await useAuditStore.getState().refresh();

    expect(useAuditStore.getState().views).toEqual([stale]);
    expect(useAuditStore.getState().auditedAt).not.toBeNull();
  });
});
