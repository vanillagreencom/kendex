// A redirected install writes into the project it was sent to, not into the
// personal subscription its packages were browsed from — so that project is
// the place whose manifest was rewritten, and the place the editor holding a
// whole copy of a manifest has to hear about.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
import { useMarketplacesStore } from "./marketplaces";
import { useProblemsStore } from "./problems";
import { useSettingsStore } from "./settings";

vi.mock("@/bindings", () => ({
  commands: {
    marketplaceInstall: vi.fn(),
    marketplacesOverview: vi.fn(),
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
    updateManifest: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn(), message: vi.fn() },
}));

vi.mock("./audit", () => ({
  useAuditStore: { getState: () => ({ refresh: vi.fn() }) },
}));

vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));

const personal = { scope: "global" as const };
const project = { scope: "project" as const, root: "/w/app" };

describe("an install redirected into a project", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useSettingsStore.setState({
      settings: { schema: 1, projects: ["/w/app"] },
    });
    vi.mocked(commands.getManifest).mockResolvedValue({
      status: "ok",
      data: { manifest: null, base: "rewritten" },
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
    // Typing arrives while the install is being written — the window this
    // file is about. Typing that was already unsaved when it started would
    // refuse the install outright, which the guard tests cover.
    vi.mocked(commands.marketplaceInstall).mockImplementation(async () => {
      useEditorStore.setState({
        draft: { schema: 1, install: {}, "skill-instructions": { gh: "mine" } },
        dirty: true,
      });
      return { status: "ok", data: [] };
    });
    // The project's Customize tab, open and clean. Unsaved typing for the
    // place an install writes now refuses the install itself, which the
    // guard tests cover; this file is about which place gets marked.
    useEditorStore.setState({
      scope: project,
      draft: { schema: 1, install: {} },
      dirty: false,
      held: {},
      outdated: null,
      saved: {},
    });
    useProblemsStore.getState().closeError();
  });

  const install = () =>
    useMarketplacesStore.getState().install({
      scope: personal,
      source: "kit",
      items: [{ kind: "skill", name: "gh" }],
      destination: project,
    });

  it("marks the project it wrote, not the subscription it was browsed from", async () => {
    await install();

    expect(commands.marketplaceInstall).toHaveBeenCalledWith(
      personal,
      "kit",
      [{ kind: "skill", name: "gh" }],
      null,
      project,
      false,
    );
    expect(useEditorStore.getState().outdated).toBe("/w/app");
  });

  it("refuses the project's next save rather than putting the manifest back", async () => {
    await install();

    vi.mocked(commands.updateManifest).mockResolvedValue({
      status: "error",
      error: { kind: "failed", message: "should never be reached" },
    });
    await useEditorStore.getState().save();

    expect(commands.updateManifest).not.toHaveBeenCalled();
    expect(useProblemsStore.getState().dialog.title).toContain(
      "changed while you typed",
    );
  });
});

// The busy flag is what holds the Customize Save bar down. The manifest
// this install rewrote only reaches the editor inside the downstream sync,
// so lowering the flag before that sync reopens the window it exists to
// close: a save landing there carries a copy read before the install.
describe("the install's busy flag", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useSettingsStore.setState({
      settings: { schema: 1, projects: ["/w/app"] },
    });
    useEditorStore.setState({
      scope: project,
      draft: null,
      dirty: false,
      held: {},
      outdated: null,
      saved: {},
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
    vi.mocked(commands.marketplaceInstall).mockResolvedValue({
      status: "ok",
      data: [],
    });
  });

  it("stays up until the manifest has been handed to the editor", async () => {
    let busyDuringSync: boolean | null = null;
    vi.mocked(commands.getManifest).mockImplementation(async () => {
      busyDuringSync = useMarketplacesStore.getState().busy;
      return { status: "ok", data: { manifest: null, base: "rewritten" } };
    });

    await useMarketplacesStore.getState().install({
      scope: personal,
      source: "kit",
      items: [{ kind: "skill", name: "gh" }],
      destination: project,
    });

    expect(busyDuringSync).toBe(true);
    expect(useMarketplacesStore.getState().busy).toBe(false);
  });

  it("comes back down when the install fails", async () => {
    vi.mocked(commands.marketplaceInstall).mockResolvedValue({
      status: "error",
      error: "nope",
    });
    await useMarketplacesStore.getState().install({
      scope: personal,
      source: "kit",
      items: [{ kind: "skill", name: "gh" }],
      destination: project,
    });
    expect(useMarketplacesStore.getState().busy).toBe(false);
  });
});
