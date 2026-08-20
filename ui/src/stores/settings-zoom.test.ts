import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useSettingsStore } from "./settings";
import { currentZoom } from "./zoom";
import {
  deferred,
  dialog,
  failed,
  freshZoomStore,
  ok,
  settings,
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

  it("resizes the window without writing anything, and writes only on commit", async () => {
    await useSettingsStore.getState().setZoom(150);

    expect(commands.windowSetZoom).toHaveBeenCalledWith(150);
    expect(zoom()).toBe(150);
    expect(commands.updateSettings).not.toHaveBeenCalled();

    await useSettingsStore.getState().saveZoom();

    expect(commands.updateSettings).toHaveBeenCalledTimes(1);
    expect(vi.mocked(commands.updateSettings).mock.calls[0][0].zoom).toBe(150);
    // The window leads the file, so what is stored is a size already shown.
    expect(
      vi.mocked(commands.windowSetZoom).mock.invocationCallOrder[0],
    ).toBeLessThan(
      vi.mocked(commands.updateSettings).mock.invocationCallOrder[0],
    );
  });

  it("keeps a size the window refused out of the settings file", async () => {
    // Starting away from ZOOM.default, so the rollback has to name the size
    // the person was working at rather than falling back to full size.
    useSettingsStore.setState({ settings: { ...settings, zoom: 150 } });
    vi.mocked(commands.windowSetZoom).mockResolvedValue(failed("no webview"));

    await useSettingsStore.getState().setZoom(160);

    expect(zoom()).toBe(150);
    expect(commands.updateSettings).not.toHaveBeenCalled();
    expect(dialog().title).toBe("Couldn't change the zoom");
    expect(dialog().message).toBe("no webview");
  });

  it("puts the size back when the bridge throws, and lets Retry ask again", async () => {
    useSettingsStore.setState({ settings: { ...settings, zoom: 150 } });
    vi.mocked(commands.windowSetZoom).mockRejectedValue(new Error("no bridge"));

    await expect(
      useSettingsStore.getState().setZoom(160),
    ).resolves.toBeUndefined();

    // Not left showing a size the window never took: the settle timer would
    // otherwise write it.
    expect(zoom()).toBe(150);
    expect(dialog().title).toBe("Couldn't change the zoom");
    expect(dialog().message).toContain("no bridge");

    vi.mocked(commands.windowSetZoom).mockResolvedValue(ok(null));
    dialog().actions[0].onClick();
    await vi.waitFor(() => expect(commands.updateSettings).toHaveBeenCalled());

    expect(commands.windowSetZoom).toHaveBeenLastCalledWith(160);
    expect(vi.mocked(commands.updateSettings).mock.calls[0][0].zoom).toBe(160);
  });

  it("does not undo a newer size when an older resize comes back refused", async () => {
    const first = deferred<ReturnType<typeof failed>>();
    vi.mocked(commands.windowSetZoom)
      .mockReturnValueOnce(first.promise)
      .mockResolvedValue(ok(null));

    // The second press is made while the first is still out: it moves the
    // store at once and waits its turn at the window.
    const refused = useSettingsStore.getState().setZoom(150);
    const next = useSettingsStore.getState().setZoom(160);
    first.settle(failed("no webview"));
    await Promise.all([refused, next]);

    expect(zoom()).toBe(160);
  });

  it("stores the size an accepted retry manages to show", async () => {
    vi.mocked(commands.windowSetZoom).mockResolvedValueOnce(
      failed("no webview"),
    );

    await useSettingsStore.getState().setZoom(150);
    const retry = dialog().actions[0];
    vi.mocked(commands.windowSetZoom).mockResolvedValue(ok(null));
    retry.onClick();
    await vi.waitFor(() => expect(commands.updateSettings).toHaveBeenCalled());

    expect(vi.mocked(commands.updateSettings).mock.calls[0][0].zoom).toBe(150);
  });
});
