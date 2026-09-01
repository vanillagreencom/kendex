// An install can leave a second question behind — what a package does to
// the repository — and the store is where that question lives: queued
// from the install's answer, asked one package at a time, and spent on
// the answer it gets.
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type Disclosure, type Scope } from "@/bindings";
import {
  repoEffectsAppliedToast,
  repoEffectsDeclinedToast,
  repoEffectsFailedTitle,
  repoEffectsSaidTitle,
  repoEffectsWithheldToast,
} from "@/lib/copy-repo-effects";
import { useMarketplacesStore } from "./marketplaces";
import { useProblemsStore } from "./problems";

vi.mock("@/bindings", () => ({
  commands: {
    marketplaceInstall: vi.fn(),
    repoEffectsApply: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), info: vi.fn(), error: vi.fn(), message: vi.fn() },
}));
vi.mock("./audit", () => ({
  useAuditStore: { getState: () => ({ refresh: vi.fn() }) },
}));
vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));

const PROJECT: Scope = { scope: "project", root: "/home/me/app" };

const disclosure = (name: string): Disclosure => ({
  declared: {
    name,
    root: `/home/me/app/.agents/skills/${name}`,
    summary: `${name} arms hooks`,
    writes: [".git/hooks/pre-commit"],
    installer: "scripts/arm",
    uninstaller: null,
    removal: null,
    notes: [],
    companions: [],
  },
  name,
  summary: `${name} arms hooks`,
  writes: [{ path: "/home/me/app/.git/hooks/pre-commit", shared: true }],
  companions: [],
  notes: [],
  undo: null,
});

const installed = (shown: Disclosure[], withheld = []) => ({
  status: "ok" as const,
  data: { packages: [], repoEffects: { shown, withheld } },
});

const install = (destination?: Scope) =>
  useMarketplacesStore.getState().install({
    scope: { scope: "global" },
    source: "cat",
    items: [{ kind: "skill", name: "guards" }],
    destination,
  });

beforeEach(() => {
  vi.clearAllMocks();
  useMarketplacesStore.setState({ pendingEffects: null, busy: false });
  useProblemsStore.getState().closeError();
});

describe("what an install leaves waiting", () => {
  it("queues the effects against the scope the files landed in", async () => {
    vi.mocked(commands.marketplaceInstall).mockResolvedValue(
      installed([disclosure("guards")]),
    );
    await install(PROJECT);
    expect(useMarketplacesStore.getState().pendingEffects).toEqual({
      scope: PROJECT,
      queue: [disclosure("guards")],
    });
  });

  it("asks nothing for a package that declares nothing", async () => {
    vi.mocked(commands.marketplaceInstall).mockResolvedValue(installed([]));
    await install();
    expect(useMarketplacesStore.getState().pendingEffects).toBeNull();
  });

  it("says which package could not be disclosed, and why", async () => {
    const { toast } = await import("sonner");
    vi.mocked(commands.marketplaceInstall).mockResolvedValue(
      installed([], [{ name: "guards", reason: "no git directory" }] as never),
    );
    await install();
    expect(toast.info).toHaveBeenCalledWith(
      repoEffectsWithheldToast("guards", "no git directory"),
    );
    expect(useMarketplacesStore.getState().pendingEffects).toBeNull();
  });
});

describe("answering", () => {
  beforeEach(() => {
    // The dialog is module state: a case that asserts none opened has to
    // start from none open.
    useProblemsStore.getState().closeError();
    useMarketplacesStore.setState({
      pendingEffects: {
        scope: PROJECT,
        queue: [disclosure("guards"), disclosure("linter")],
      },
    });
  });

  it("a yes runs the declaration that was shown, in that scope, and shows the installer's own last word", async () => {
    const { toast } = await import("sonner");
    vi.mocked(commands.repoEffectsApply).mockResolvedValue({
      status: "ok",
      data: {
        stdout: ["writing helper", "hooks: skipped — core.hooksPath is set"],
        stderr: [],
      },
    });
    expect(await useMarketplacesStore.getState().applyRepoEffect()).toBe(true);
    expect(commands.repoEffectsApply).toHaveBeenCalledWith(
      PROJECT,
      disclosure("guards").declared,
    );
    // Not "Applied": the installer said it armed nothing, and that is
    // what the person reads.
    expect(toast.success).toHaveBeenCalledWith(
      "hooks: skipped — core.hooksPath is set",
    );
    expect(useMarketplacesStore.getState().pendingEffects?.queue).toEqual([
      disclosure("linter"),
    ]);
  });

  it("a silent installer gets the canned line", async () => {
    const { toast } = await import("sonner");
    vi.mocked(commands.repoEffectsApply).mockResolvedValue({
      status: "ok",
      data: { stdout: [], stderr: [] },
    });
    await useMarketplacesStore.getState().applyRepoEffect();
    expect(toast.success).toHaveBeenCalledWith(
      repoEffectsAppliedToast("guards"),
    );
  });

  it("a trailing blank line is not the installer's last word", async () => {
    const { toast } = await import("sonner");
    vi.mocked(commands.repoEffectsApply).mockResolvedValue({
      status: "ok",
      data: { stdout: ["hooks armed", "", "  "], stderr: [] },
    });
    await useMarketplacesStore.getState().applyRepoEffect();
    expect(toast.success).toHaveBeenCalledWith("hooks armed");
  });

  it("an installer that printed only blank lines gets the canned line", async () => {
    const { toast } = await import("sonner");
    vi.mocked(commands.repoEffectsApply).mockResolvedValue({
      status: "ok",
      data: { stdout: ["", ""], stderr: [] },
    });
    await useMarketplacesStore.getState().applyRepoEffect();
    expect(toast.success).toHaveBeenCalledWith(
      repoEffectsAppliedToast("guards"),
    );
  });

  it("a clean exit with something on stderr still reaches the person", async () => {
    const { toast } = await import("sonner");
    vi.mocked(commands.repoEffectsApply).mockResolvedValue({
      status: "ok",
      data: {
        stdout: ["hooks: skipped"],
        stderr: ["core.hooksPath is set", "unset it and run this again"],
      },
    });
    expect(await useMarketplacesStore.getState().applyRepoEffect()).toBe(true);
    // The summary is the headline; the remedy is the part a toast drops.
    expect(toast.success).toHaveBeenCalledWith("hooks: skipped");
    const { dialog } = useProblemsStore.getState();
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe(repoEffectsSaidTitle("guards"));
    expect(dialog.message).toBe(
      "core.hooksPath is set\nunset it and run this again\nhooks: skipped",
    );
  });

  it("a clean exit with nothing on stderr opens no dialog", async () => {
    vi.mocked(commands.repoEffectsApply).mockResolvedValue({
      status: "ok",
      data: { stdout: ["hooks armed"], stderr: ["", "  "] },
    });
    await useMarketplacesStore.getState().applyRepoEffect();
    expect(useProblemsStore.getState().dialog.open).toBe(false);
  });

  it("a no runs nothing and says the package is installed unarmed", async () => {
    const { toast } = await import("sonner");
    useMarketplacesStore.getState().declineRepoEffect();
    expect(commands.repoEffectsApply).not.toHaveBeenCalled();
    expect(toast.info).toHaveBeenCalledWith(repoEffectsDeclinedToast("guards"));
    expect(useMarketplacesStore.getState().pendingEffects?.queue).toEqual([
      disclosure("linter"),
    ]);
  });

  it("the last answer closes the question", () => {
    useMarketplacesStore.getState().declineRepoEffect();
    useMarketplacesStore.getState().declineRepoEffect();
    expect(useMarketplacesStore.getState().pendingEffects).toBeNull();
  });

  it("a failed installer opens the error dialog with the whole account, and the line still moves on", async () => {
    const { toast } = await import("sonner");
    const account =
      "guards: scripts/arm exited 1 — anything it wrote before that is still there; the package declares no way to undo it\ncould not write hooks";
    vi.mocked(commands.repoEffectsApply).mockResolvedValue({
      status: "error",
      error: account,
    });
    expect(await useMarketplacesStore.getState().applyRepoEffect()).toBe(false);
    expect(toast.error).not.toHaveBeenCalled();
    const { dialog } = useProblemsStore.getState();
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe(repoEffectsFailedTitle("guards"));
    expect(dialog.message).toBe(account);
    expect(useMarketplacesStore.getState().pendingEffects?.queue).toEqual([
      disclosure("linter"),
    ]);
  });
});

// An install plans the whole scope, so its plan can take a package away
// as well as bring one — and a package that leaves has its uninstaller run
// before its scripts go. That is not the second question the dialog asks;
// it already happened, and the window says so.
describe("what an install says about a package that left with it", () => {
  const RAN = "growth-guards: running scripts/install-git-hooks --uninstall";

  it("says what the install ran in the repository", async () => {
    vi.mocked(commands.marketplaceInstall).mockResolvedValue({
      status: "ok",
      data: {
        packages: [],
        repoEffects: { shown: [], withheld: [] },
        undone: [RAN],
      },
    });

    await install();

    expect(toast.message).toHaveBeenCalledWith(RAN);
  });

  it("stays quiet when the install took no armed package away", async () => {
    vi.mocked(toast.message).mockClear();
    vi.mocked(commands.marketplaceInstall).mockResolvedValue(installed([]));

    await install();

    expect(toast.message).not.toHaveBeenCalled();
  });
});
