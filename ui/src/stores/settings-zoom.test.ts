import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppSettings } from "@/bindings";
import { commands, ZOOM } from "@/bindings";
import { useProblemsStore } from "./problems";
import { useSettingsStore } from "./settings";
import { zoom as controls, currentZoom } from "./zoom";

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
  },
  ZOOM: { min: 50, max: 200, step: 10, default: 100 },
}));

vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const settings: AppSettings = {
  schema: 1,
  appearance: "system",
  "harness-roots": {},
  projects: [],
  zoom: 100,
};

const ok = <T>(data: T) => ({ status: "ok" as const, data });
const failed = (error: string) => ({ status: "error" as const, error });

/** Let everything already queued run before carrying on. */
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/** A promise whose settling the test decides. */
function deferred<T>() {
  let settle: (value: T) => void = () => {};
  const promise = new Promise<T>((resolve) => {
    settle = resolve;
  });
  return { promise, settle };
}

/** What the app is showing, which a press moves ahead of the window. */
const zoom = () => currentZoom();
/** What a save would carry: the size the shared settings object holds. */
const stored = () => useSettingsStore.getState().settings?.zoom;
const dialog = () => useProblemsStore.getState().dialog;

/** The size the stand-in webview is at. It keeps its own, the way the real
 *  one does: the zoom outlives the page, so a reload has to read it back. */
let webviewAt = settings.zoom ?? 100;

/** Put the stand-in webview at a size, as a launch or an accepted resize
 *  would. A test that seeds the store away from full size moves the window
 *  with it — the store's copy is what is being drawn, and the window is
 *  what a refusal reads the real size back from. */
function windowAt(percent: number) {
  webviewAt = percent;
}

/** A window that takes every size it is asked for, and remembers it. */
function windowTakes() {
  vi.mocked(commands.windowSetZoom).mockImplementation(async (percent) => {
    webviewAt = percent;
    return ok(null);
  });
}

/** A store at 100%, a closed dialog, and a window that takes every size —
 *  including at launch, so the store opens where the stored size is. */
function freshZoomStore() {
  webviewAt = settings.zoom ?? 100;
  useSettingsStore.setState({ settings, zoom: webviewAt, capabilities: [] });
  useProblemsStore.setState({
    dialog: { open: false, title: "", steps: [], actions: [] },
  });
  vi.clearAllMocks();
  windowTakes();
  vi.mocked(commands.windowZoomState).mockImplementation(async () => ({
    percent: webviewAt,
    launchRefused: false,
  }));
  vi.mocked(commands.updateSettings).mockImplementation(async (next, base) =>
    ok({ settings: next, base }),
  );
  vi.mocked(commands.saveZoom).mockImplementation(async (percent) =>
    ok(percent),
  );
  expect(zoom()).toBe(100);
}

describe("zoom, on screen", () => {
  beforeEach(freshZoomStore);

  /// Settings that arrived without an explicit size are not the same as
  /// settings that have not arrived: the first means the default, and
  /// treating it as unknown would leave the zoom controls dead.
  it("reads the default size from settings that carry none", () => {
    const { zoom: _z, ...withoutZoom } = settings;
    useSettingsStore.setState({ settings: withoutZoom });
    expect(currentZoom()).toBe(100);

    useSettingsStore.setState({ settings: null });
    expect(currentZoom()).toBeNull();
  });

  /// The launch could not apply the stored size, so the window is at full
  /// size. Settings has to read the size in front of the person and step
  /// from it: a readout of the stored size would name a size nobody is
  /// looking at, and the next press would move from there.
  it("reads the size a launch that could not zoom actually opened at", async () => {
    useSettingsStore.setState({ settings: null, zoom: null });
    vi.mocked(commands.getSettings).mockResolvedValue(
      ok({ settings: { ...settings, zoom: 150 }, base: "file" }),
    );
    vi.mocked(commands.capabilityTable).mockResolvedValue([]);
    vi.mocked(commands.windowZoomState).mockResolvedValue({
      percent: 100,
      launchRefused: true,
    });

    await useSettingsStore.getState().load();

    expect(zoom()).toBe(100);
    expect(dialog().title).toBe("Couldn't open at your saved zoom");

    controls.step(ZOOM.step);
    await tick();

    // Stepped from the size on screen, and the size the person asked for is
    // still theirs: a session the window would not honour it in does not
    // take it away.
    expect(commands.windowSetZoom).toHaveBeenLastCalledWith(110);
    expect(stored()).toBe(150);

    controls.flush();
    await tick();
  });

  /// The webview keeps its zoom across a page reload and the page does not,
  /// so the reloaded page has to read the size back rather than assume the
  /// opening still speaks for it. Getting this wrong shows the opening size
  /// at a resized window, raises a failure for an opening that worked, and
  /// steps the person backwards.
  it("re-reads the size the window is at when the page reloads", async () => {
    await useSettingsStore.getState().setZoom(150);
    await useSettingsStore.getState().saveZoom();

    // The reload: a new store, and a window still at the resized size.
    useSettingsStore.setState({
      settings: null,
      zoom: null,
    });
    vi.mocked(commands.getSettings).mockResolvedValue(
      ok({ settings: { ...settings, zoom: 150 }, base: "file" }),
    );
    vi.mocked(commands.capabilityTable).mockResolvedValue([]);

    await useSettingsStore.getState().load();

    expect(dialog().open).toBe(false);
    expect(zoom()).toBe(150);

    controls.step(ZOOM.step);
    await tick();

    expect(commands.windowSetZoom).toHaveBeenLastCalledWith(160);

    controls.flush();
    await tick();
  });

  it("resizes the window without writing anything, and writes only on commit", async () => {
    await useSettingsStore.getState().setZoom(150);

    expect(commands.windowSetZoom).toHaveBeenCalledWith(150);
    expect(zoom()).toBe(150);
    expect(commands.saveZoom).not.toHaveBeenCalled();

    await useSettingsStore.getState().saveZoom();

    expect(commands.saveZoom).toHaveBeenCalledTimes(1);
    expect(vi.mocked(commands.saveZoom).mock.calls[0][0]).toBe(150);
    // The window leads the file, so what is stored is a size already shown.
    expect(
      vi.mocked(commands.windowSetZoom).mock.invocationCallOrder[0],
    ).toBeLessThan(vi.mocked(commands.saveZoom).mock.invocationCallOrder[0]);
  });

  it("keeps a size the window refused out of the settings file", async () => {
    // Starting away from ZOOM.default, so the rollback has to name the size
    // the person was working at rather than falling back to full size.
    useSettingsStore.setState({
      settings: { ...settings, zoom: 150 },
      zoom: 150,
    });
    windowAt(150);
    vi.mocked(commands.windowSetZoom).mockResolvedValue(failed("no webview"));

    await useSettingsStore.getState().setZoom(160);

    expect(zoom()).toBe(150);
    expect(commands.saveZoom).not.toHaveBeenCalled();
    expect(dialog().title).toBe("Couldn't change the zoom");
    expect(dialog().message).toBe("no webview");
  });

  it("puts the size back when the bridge throws, and lets Retry ask again", async () => {
    useSettingsStore.setState({
      settings: { ...settings, zoom: 150 },
      zoom: 150,
    });
    windowAt(150);
    vi.mocked(commands.windowSetZoom).mockRejectedValue(new Error("no bridge"));

    await expect(
      useSettingsStore.getState().setZoom(160),
    ).resolves.toBeUndefined();

    // Not left showing a size the window never took: the settle timer would
    // otherwise write it.
    expect(zoom()).toBe(150);
    expect(dialog().title).toBe("Couldn't change the zoom");
    expect(dialog().message).toContain("no bridge");

    windowTakes();
    dialog().actions[0].onClick();
    await vi.waitFor(() => expect(commands.saveZoom).toHaveBeenCalled());

    expect(commands.windowSetZoom).toHaveBeenLastCalledWith(160);
    expect(vi.mocked(commands.saveZoom).mock.calls[0][0]).toBe(160);
  });

  /// A refusal is about the press that was refused. Another press made
  /// while it was out has already moved the display past it, and putting
  /// the old size back would take the person off the size they are looking
  /// at because an earlier one failed.
  it("does not undo a newer size when an older resize comes back refused", async () => {
    const first = deferred<ReturnType<typeof failed>>();
    vi.mocked(commands.windowSetZoom).mockReturnValueOnce(first.promise);

    const refused = useSettingsStore.getState().setZoom(150);
    const next = useSettingsStore.getState().setZoom(160);
    first.settle(failed("no webview"));
    await Promise.all([refused, next]);

    expect(zoom()).toBe(160);
  });

  /// Two presses out and both refused: the display goes back to the size
  /// the window says it is at, never to the other refused one — which it
  /// is not showing either.
  it("puts back the size the window is showing, not one it also refused", async () => {
    const first = deferred<ReturnType<typeof failed>>();
    const second = deferred<ReturnType<typeof failed>>();
    vi.mocked(commands.windowSetZoom)
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);

    const step = useSettingsStore.getState().setZoom(150);
    const next = useSettingsStore.getState().setZoom(160);
    first.settle(failed("no webview"));
    await tick();
    second.settle(failed("no webview"));
    await Promise.all([step, next]);
    await useSettingsStore.getState().saveZoom();

    // The window never left 100, so 100 is what the file gets.
    expect(zoom()).toBe(100);
    expect(vi.mocked(commands.saveZoom).mock.calls[0][0]).toBe(100);
  });

  /// The window is the authority on the size to store. A press moves the
  /// display ahead of it, and one the window refused while even the
  /// rollback's read failed leaves it ahead for good — written, that size
  /// outlives the session and asks for the same refusal at every launch.
  /// A run that cannot read the window has nothing to write and says so.
  it("writes nothing when the window cannot say what size it is at", async () => {
    await useSettingsStore.getState().setZoom(150);
    vi.mocked(commands.windowZoomState).mockRejectedValue(
      new Error("no bridge"),
    );

    await useSettingsStore.getState().saveZoom();

    expect(commands.saveZoom).not.toHaveBeenCalled();
    expect(dialog().open).toBe(true);
    expect(dialog().title).toBe("Couldn't save the zoom");
  });

  it("stores the size an accepted retry manages to show", async () => {
    vi.mocked(commands.windowSetZoom).mockResolvedValueOnce(
      failed("no webview"),
    );

    await useSettingsStore.getState().setZoom(150);
    const retry = dialog().actions[0];
    windowTakes();
    retry.onClick();
    await vi.waitFor(() => expect(commands.saveZoom).toHaveBeenCalled());

    expect(vi.mocked(commands.saveZoom).mock.calls[0][0]).toBe(150);
  });
});
