import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppSettings } from "@/bindings";
import { commands } from "@/bindings";
import { useEditorStore } from "./editor";
import { useSettingsStore } from "./settings";

vi.mock("@/bindings", () => ({
  commands: {
    getSettings: vi.fn(),
    capabilityTable: vi.fn(),
    updateSettings: vi.fn(),
    registerProject: vi.fn(),
    unregisterProject: vi.fn(),
    discoverProjects: vi.fn(),
    scanMachine: vi.fn(),
    windowSetZoom: vi.fn(),
    windowZoomState: vi.fn(),
    saveZoom: vi.fn(),
    installDriftHook: vi.fn(),
    getManifest: vi.fn(),
    editorInventory: vi.fn(),
  },
  ZOOM: { min: 50, max: 200, step: 10, default: 100 },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn() },
}));

const settings: AppSettings = {
  schema: 1,
  appearance: "system",
  safety: { "warn-below": 80, "block-below": 60 },
  "harness-roots": {},
  projects: [],
  zoom: 100,
};

// Adding the session drift report declares a hook in that project's
// kendex.toml, so the Customize tab holding a copy of that file has to
// hear about it like it does for every other write.
describe("adding the drift report to a project", () => {
  const root = "/work/vg";

  beforeEach(() => {
    vi.clearAllMocks();
    useSettingsStore.setState({ settings: null });
    useEditorStore.setState({
      scope: { scope: "project", root },
      draft: { schema: 1, install: {} },
      dirty: false,
      held: {},
      outdated: null,
      saved: {},
    });
    vi.mocked(commands.registerProject).mockResolvedValue({
      status: "ok",
      data: { ...settings, projects: [root] },
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.installDriftHook).mockResolvedValue({
      status: "ok",
      data: true,
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
  });

  /** Every queued microtask and one macrotask, so "still busy" means it. */
  const settle = () => new Promise((done) => setTimeout(done, 0));

  function deferred<T>() {
    let resolve!: (value: T) => void;
    const promise = new Promise<T>((keep) => {
      resolve = keep;
    });
    return { promise, resolve };
  }

  /** The offer is a toast action, and taking it is what writes. */
  const takeTheOffer = async () => {
    await useSettingsStore.getState().registerProject(root);
    const offer = vi.mocked(toast.success).mock.calls.at(-1)?.[1] as
      | { action?: { onClick: () => void } }
      | undefined;
    offer?.action?.onClick();
  };

  it("tells the editor the project's settings were written", async () => {
    // Typing arrives while the hook is being written — the window between
    // the write and the telling.
    vi.mocked(commands.installDriftHook).mockImplementation(async () => {
      useEditorStore.setState({
        draft: { schema: 1, install: {}, "skill-instructions": { gh: "mine" } },
        dirty: true,
      });
      return { status: "ok", data: true };
    });
    await takeTheOffer();
    await vi.waitUntil(() => useEditorStore.getState().outdated !== null);

    expect(commands.installDriftHook).toHaveBeenCalled();
    // The typing is kept and the place is marked, so the next save is
    // refused rather than writing the hook declaration back out.
    expect(useEditorStore.getState().outdated).toBe(root);
    expect(useEditorStore.getState().dirty).toBe(true);
  });

  // A toast is offered per project, so two can be open at once. The flag
  // they share is what holds the Customize Save bar down, and it belongs to
  // every write in flight rather than to whichever lands first.
  it("holds the gate down until the last write lands", async () => {
    const first = deferred<{ status: "ok"; data: boolean }>();
    const second = deferred<{ status: "ok"; data: boolean }>();
    vi.mocked(commands.installDriftHook)
      .mockReturnValueOnce(first.promise as never)
      .mockReturnValueOnce(second.promise as never);

    await takeTheOffer();
    await takeTheOffer();
    expect(useSettingsStore.getState().busy).toBe(true);

    first.resolve({ status: "ok", data: true });
    // Every turn the first write's chain needs, its own `finally` included
    // — the moment a flag belonging to one operation would come down.
    await settle();
    await settle();
    // The second project's file is still being written.
    expect(useSettingsStore.getState().busy).toBe(true);

    second.resolve({ status: "ok", data: true });
    await vi.waitUntil(() => !useSettingsStore.getState().busy);
  });

  // The declaration lands in the same file the Customize tab edits, so it
  // waits for unsaved typing there like every other writer of it.
  it("does not write while that project has an unsaved draft", async () => {
    useEditorStore.setState({
      draft: { schema: 1, install: {}, "skill-instructions": { gh: "mine" } },
      dirty: true,
    });
    await takeTheOffer();

    expect(commands.installDriftHook).not.toHaveBeenCalled();
    expect(useEditorStore.getState().dirty).toBe(true);
  });
});
