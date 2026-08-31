import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands, ZOOM } from "@/bindings";
import { useSettingsStore } from "./settings";
import { zoom as controls, currentZoom } from "./zoom";
import {
  deferred,
  dialog,
  failed,
  freshZoomStore,
  ok,
  settings,
  stored,
  tick,
  windowAt,
  windowTakes,
  zoom,
} from "./zoom-fixture";

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
