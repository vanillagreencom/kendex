// One rule, one wrapper: a command that reaches `repo_effects` reads the
// machine again whatever it answered. `lib/rescan.ts` holds the rule and
// the reason a refusal is no account of the disk.
//
// The refusal arm is what the first cases are about, and the wrapper cannot
// tell it from the landing one. The landing arm is not where this file's
// coverage was thin, but it was not whole either: the editor refreshed the
// audit and the scan without the join, and an item action refreshed the scan
// alone. `rescanEverything` sends three reads, and `readAgain` below says
// which two of them every case asks about.
//
// Nothing waits on those reads, so `rescansSettled` is what a test waits on.
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, Disclosure, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { emptyDraft } from "@/lib/editor-draft";
import { READ_LANDED } from "@/lib/read-state";
import { rescansSettled } from "@/lib/rescan";
import { useAuditStore } from "./audit";
import { useEditorStore } from "./editor";
import { useMarketplacesStore } from "./marketplaces";
import { useProvenanceStore } from "./provenance";
import { useScanStore } from "./scan";
import { useSettingsStore } from "./settings";

vi.mock("@/bindings", async (importOriginal) => ({
  // The generated constants stay real — the editor's empty draft is stamped
  // with core's own manifest schema through them.
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    marketplaceInstall: vi.fn(),
    marketplaceSubscribe: vi.fn(),
    marketplaceUnsubscribe: vi.fn(),
    marketplacesOverview: vi.fn(),
    repoEffectsApply: vi.fn(),
    sourceToggle: vi.fn(),
    installDriftHook: vi.fn(),
    registerProject: vi.fn(),
    saveCustomize: vi.fn(),
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    getScopeSettings: vi.fn(),
    adoptItem: vi.fn(),
    removeItem: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    libraryProvenance: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: {
    error: vi.fn(),
    success: vi.fn(),
    info: vi.fn(),
    message: vi.fn(),
  },
}));

const scope: Scope = { scope: "global" };

const view = (at: Scope): AuditView => ({
  scope: at,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
});

const disclosure: Disclosure = {
  declared: {
    name: "guards",
    root: "/home/me/app/.agents/skills/guards",
    summary: "guards arms hooks",
    writes: [".git/hooks/pre-commit"],
    installer: "scripts/arm",
    uninstaller: null,
    removal: null,
    notes: [],
    companions: [],
  },
  name: "guards",
  summary: "guards arms hooks",
  writes: [{ path: "/home/me/app/.git/hooks/pre-commit", shared: true }],
  companions: [],
  notes: [],
  undo: null,
};

/** A promise this test lands by hand, to hold a read open across a loop. */
const park = <T>() => {
  let land: (value: T) => void = () => {};
  const parked = new Promise<T>((resolve) => {
    land = resolve;
  });
  return { parked, land: (value: T) => land(value) };
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: {
      items: [],
      harnesses: [],
      warnings: [],
      missingProjects: [],
    } as never,
  });
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  vi.mocked(commands.libraryProvenance).mockResolvedValue({
    status: "ok",
    data: [],
  });
  useScanStore.setState({
    scanning: false,
    result: null,
    error: null,
    backgroundFailureAnnounced: false,
  });
  useAuditStore.setState({
    views: [],
    auditing: false,
    auditedAt: null,
    read: READ_LANDED,
    busy: false,
    backgroundFailureAnnounced: false,
  });
  useProvenanceStore.setState({ rows: [], loaded: false });
  useMarketplacesStore.setState({ busy: false, error: null });
});

/** What every case below asks: the machine was read again behind a command
 *  that answered with a refusal. Two of the three reads, not all of them —
 *  the provenance join's read answers nothing at all, publishing how it
 *  went as its store's own read state, and no store mocked here would tell
 *  a join that ran from one that could not, so it is asserted through
 *  neither. */
const readAgain = () => {
  expect(commands.scanMachine).toHaveBeenCalled();
  expect(commands.auditAll).toHaveBeenCalled();
};

describe("a write that reaches repo_effects and is refused", () => {
  it("reads the machine again behind a marketplace install", async () => {
    vi.mocked(commands.marketplaceInstall).mockResolvedValue({
      status: "error",
      error: "the scope is busy",
    });

    const landed = await useMarketplacesStore.getState().install({
      scope,
      source: "kit",
      items: [{ kind: "skill", name: "gh" }],
    });
    await rescansSettled();

    expect(landed).toBe(false);
    readAgain();
  });

  // Subscribing writes its report through the one executor like any other,
  // which is why the outcome carries an account to say.
  it("reads the machine again behind a subscribe", async () => {
    vi.mocked(commands.marketplaceSubscribe).mockResolvedValue({
      status: "error",
      error: "already subscribed",
    });

    const outcome = await useMarketplacesStore
      .getState()
      .subscribe(scope, "acme/kit", null);
    await rescansSettled();

    expect(outcome).toEqual({ error: "already subscribed" });
    readAgain();
  });

  it("reads the machine again behind a source toggle", async () => {
    vi.mocked(commands.sourceToggle).mockResolvedValue({
      status: "error",
      error: "the settings file is read-only",
    });

    await useMarketplacesStore.getState().toggle(scope, "kit", false);
    await rescansSettled();

    // The refusal is honoured — the overview is not re-asked behind a write
    // that did not land — and the machine is still read again.
    expect(commands.marketplacesOverview).not.toHaveBeenCalled();
    readAgain();
  });

  it("reads the machine again behind an unsubscribe", async () => {
    vi.mocked(commands.marketplaceUnsubscribe).mockResolvedValue({
      status: "error",
      error: "the scope is busy",
    });

    const outcome = await useMarketplacesStore
      .getState()
      .unsubscribe(scope, "kit", false, false);
    await rescansSettled();

    expect(outcome).toEqual({ error: "the scope is busy" });
    readAgain();
  });

  // The package's own installer runs in the repository, and a failure is by
  // this action's own account a possibly half-written one.
  it("reads the machine again behind a repository effect", async () => {
    vi.mocked(commands.repoEffectsApply).mockResolvedValue({
      status: "error",
      error: "the installer exited 1",
    });
    useMarketplacesStore.setState({
      pendingEffects: { scope, queue: [disclosure] },
    });

    const landed = await useMarketplacesStore.getState().applyRepoEffect();
    await rescansSettled();

    expect(landed).toBe(false);
    readAgain();
  });

  // The drift hook is applied before the command can answer either way, so
  // its refusal comes back with the hook already on disk.
  it("reads the machine again behind a drift-report install", async () => {
    const { toast } = await import("sonner");
    vi.mocked(commands.registerProject).mockResolvedValue({
      status: "ok",
      data: { settings: { projects: ["/home/me/app"] }, base: null } as never,
    });
    await useSettingsStore.getState().registerProject("/home/me/app");
    await rescansSettled();
    // The registration's own read is not what this case is about.
    vi.mocked(commands.scanMachine).mockClear();
    vi.mocked(commands.auditAll).mockClear();

    vi.mocked(commands.installDriftHook).mockResolvedValue({
      status: "error",
      error: "the hook folder is read-only",
    });
    // The offer is the toast's own action: pressed, as a person presses it.
    const offer = vi.mocked(toast.success).mock.calls.at(-1)?.[1]?.action;
    if (typeof offer !== "object" || offer === null || !("onClick" in offer))
      throw new Error("the registration offered no drift report to install");
    offer.onClick(null as never);
    // The handler answers nothing to await — a toast action returns void —
    // so the queue is drained before asking what the reads did.
    await new Promise((resolve) => setTimeout(resolve, 0));
    await rescansSettled();

    expect(commands.installDriftHook).toHaveBeenCalled();
    readAgain();
  });

  it("reads the machine again behind an editor save", async () => {
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "disk is full" },
    });
    useEditorStore.setState({ scope, draft: emptyDraft(), base: null });

    await useEditorStore.getState().save();
    await rescansSettled();

    expect(useEditorStore.getState().error).toBe("disk is full");
    readAgain();
  });

  // The stale arm claims nothing was written, and is still no account of the
  // disk: two routes answer with it — the base check before anything ran,
  // and a rollback the save decided reads as the reload choice — and from
  // the UI they are one answer. The read is unconditional rather than argued
  // from what a stale answer proves.
  it("reads the machine again behind an editor save refused as stale", async () => {
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "error",
      error: { kind: "stale" },
    });
    useEditorStore.setState({ scope, draft: emptyDraft(), base: null });

    await useEditorStore.getState().save();
    await rescansSettled();

    expect(useEditorStore.getState().stale).toBe(true);
    readAgain();
  });

  it("reads the machine again behind an audit item action", async () => {
    vi.mocked(commands.removeItem).mockResolvedValue({
      status: "error",
      error: "permission denied",
    });

    const landed = await useAuditStore
      .getState()
      .removeItem(scope, "hook", "lint");
    await rescansSettled();

    expect(landed).toBe(false);
    readAgain();
  });
});

// The arm with nobody able to say what the engine got as far as. A refusal
// is at least an answer; a rejection is the transport failing over a command
// that may have written throughout — `bindings.ts`'s `typedError` rethrows
// an Error rather than folding it into a refusal, so this reaches the stores
// as a rejection and always has.
describe("a write that reaches repo_effects and throws", () => {
  it("reads the machine again when the command rejects rather than refuses", async () => {
    vi.mocked(commands.marketplaceInstall).mockRejectedValue(
      new Error("ipc closed"),
    );

    await expect(
      useMarketplacesStore.getState().install({
        scope,
        source: "kit",
        items: [{ kind: "skill", name: "gh" }],
      }),
    ).rejects.toThrow("ipc closed");
    await rescansSettled();

    readAgain();
  });

  // Not only the command's own failure: the editor's re-read after a landed
  // save is three commands under one `Promise.all`, with no `settled` over
  // it, so a rejection there throws out of the caller's own body.
  it("reads the machine again when the caller's own re-read throws", async () => {
    vi.mocked(commands.saveCustomize).mockResolvedValue({
      status: "ok",
      data: view(scope) as never,
    });
    vi.mocked(commands.getManifest).mockRejectedValue(new Error("ipc closed"));
    useEditorStore.setState({ scope, draft: emptyDraft(), base: null });

    await expect(useEditorStore.getState().save()).rejects.toThrow(
      "ipc closed",
    );
    await rescansSettled();

    readAgain();
  });
});

// The read behind a write is the only one that can answer for it: a scan
// already out began reading before the write landed. Dropping the write's
// own scan because one was in flight left Home's inventory — which renders
// from that result — counting copies the write had just taken off disk,
// with the footer saying "scanned just now" over it.
describe("a write under a scan that was already out", () => {
  it("still gets a scan of its own, behind the one running", async () => {
    const focus = park<Awaited<ReturnType<typeof commands.scanMachine>>>();
    vi.mocked(commands.scanMachine)
      .mockReturnValueOnce(
        focus.parked as ReturnType<typeof commands.scanMachine>,
      )
      .mockResolvedValue({
        status: "ok",
        data: {
          items: [],
          harnesses: [],
          warnings: [],
          missingProjects: [],
        } as never,
      });
    vi.mocked(commands.removeItem).mockResolvedValue({
      status: "ok",
      data: view(scope),
    });

    // What App.tsx fires when the window comes back, unawaited.
    void useScanStore.getState().refresh();
    await useAuditStore.getState().removeItem(scope, "hook", "lint");

    focus.land({
      status: "ok",
      data: {
        items: [],
        harnesses: [],
        warnings: [],
        missingProjects: [],
      } as never,
    });
    await rescansSettled();

    // The focus scan, and the write's own behind it.
    expect(commands.scanMachine).toHaveBeenCalledTimes(2);
  });
});

// A page of writes goes out one at a time and each one asks for the same
// machine-wide read. Paying for one per write is seconds per item — the
// audit leg alone measured p50 0.75s over this machine's scopes, never
// served from its freshness window because the rescan forces it.
describe("a page of writes, one after another", () => {
  it("pays one read for a run of adopts rather than one each", async () => {
    const held = park<{ status: "ok"; data: AuditView[] }>();
    vi.mocked(commands.auditAll)
      .mockReturnValueOnce(held.parked as ReturnType<typeof commands.auditAll>)
      .mockResolvedValue({ status: "ok", data: [] });
    vi.mocked(commands.adoptItem).mockResolvedValue({
      status: "ok",
      data: view(scope),
    });

    // What "Start managing all" does: one item at a time, each awaited, so
    // nothing overlaps and nothing coalesces on its own.
    for (const name of ["gh", "lint", "fmt", "test", "deploy"]) {
      await useAuditStore.getState().adopt(scope, "hook", name, ["claude"]);
    }

    expect(commands.adoptItem).toHaveBeenCalledTimes(5);
    // One read out, and the other four asking joined the one waiting behind
    // it rather than each starting their own.
    expect(commands.auditAll).toHaveBeenCalledTimes(1);
    expect(commands.scanMachine).toHaveBeenCalledTimes(1);

    held.land({ status: "ok", data: [] });
    await rescansSettled();

    // The waiting one starts only once the first has finished, which is
    // after the last write landed — so the run is still read for.
    expect(commands.auditAll).toHaveBeenCalledTimes(2);
    expect(commands.scanMachine).toHaveBeenCalledTimes(2);
  });

  it("pays one read for a delete across every scope a package lives in", async () => {
    const held = park<{ status: "ok"; data: AuditView[] }>();
    vi.mocked(commands.auditAll)
      .mockReturnValueOnce(held.parked as ReturnType<typeof commands.auditAll>)
      .mockResolvedValue({ status: "ok", data: [] });
    const scopes: Scope[] = [
      { scope: "global" },
      { scope: "project", root: "/home/me/app" },
      { scope: "project", root: "/home/me/other" },
    ];
    vi.mocked(commands.removeItem).mockResolvedValue({
      status: "ok",
      data: view(scope),
    });

    for (const at of scopes) {
      await useAuditStore.getState().removeItem(at, "skill", "gh");
    }

    expect(commands.removeItem).toHaveBeenCalledTimes(3);
    expect(commands.auditAll).toHaveBeenCalledTimes(1);

    held.land({ status: "ok", data: [] });
    await rescansSettled();

    expect(commands.auditAll).toHaveBeenCalledTimes(2);
  });
});
