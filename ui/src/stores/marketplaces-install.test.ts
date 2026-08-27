// An install can leave a second question behind — what a package does to
// the repository — and the store is where that question lives: queued
// from the install's answer, asked one package at a time, and spent on
// the answer it gets.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, type Disclosure, type Scope } from "@/bindings";
import {
  repoEffectsAppliedToast,
  repoEffectsDeclinedToast,
  repoEffectsWithheldToast,
} from "@/lib/copy-repo-effects";
import { useMarketplacesStore } from "./marketplaces";

vi.mock("@/bindings", () => ({
  commands: {
    marketplaceInstall: vi.fn(),
    repoEffectsApply: vi.fn(),
  },
}));
vi.mock("sonner", () => ({
  toast: { success: vi.fn(), info: vi.fn(), error: vi.fn() },
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
  writes: [{ path: "/home/me/app/.git/hooks/pre-commit", shared: true }],
  companions: [],
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
    useMarketplacesStore.setState({
      pendingEffects: {
        scope: PROJECT,
        queue: [disclosure("guards"), disclosure("linter")],
      },
    });
  });

  it("a yes runs the declaration that was shown, in that scope, and moves on", async () => {
    const { toast } = await import("sonner");
    vi.mocked(commands.repoEffectsApply).mockResolvedValue({
      status: "ok",
      data: null,
    });
    expect(await useMarketplacesStore.getState().applyRepoEffect()).toBe(true);
    expect(commands.repoEffectsApply).toHaveBeenCalledWith(
      PROJECT,
      disclosure("guards").declared,
    );
    expect(toast.success).toHaveBeenCalledWith(
      repoEffectsAppliedToast("guards"),
    );
    expect(useMarketplacesStore.getState().pendingEffects?.queue).toEqual([
      disclosure("linter"),
    ]);
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

  it("a failed installer is reported and the line still moves on", async () => {
    const { toast } = await import("sonner");
    vi.mocked(commands.repoEffectsApply).mockResolvedValue({
      status: "error",
      error: "scripts/arm exited 1",
    });
    expect(await useMarketplacesStore.getState().applyRepoEffect()).toBe(false);
    expect(toast.error).toHaveBeenCalledWith("scripts/arm exited 1");
    expect(useMarketplacesStore.getState().pendingEffects?.queue).toEqual([
      disclosure("linter"),
    ]);
  });
});
