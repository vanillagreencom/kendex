import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useSettingsStore } from "./settings";
import {
  deferred,
  failed,
  freshZoomStore,
  ok,
  settings,
  tick,
  type WindowReply,
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

describe("zoom, with a resize still out", () => {
  beforeEach(freshZoomStore);

  it("waits for a resize that starts while the commit is already waiting", async () => {
    const first = deferred<WindowReply>();
    const second = deferred<WindowReply>();
    vi.mocked(commands.windowSetZoom)
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);

    // A pointer release lands between the drag's last two steps, so both
    // resizes are still out when the commit starts waiting.
    const step = useSettingsStore.getState().setZoom(150);
    const saved = useSettingsStore.getState().saveZoom();
    const last = useSettingsStore.getState().setZoom(160);
    first.settle(ok(null));
    // Long enough for the commit to notice the first resize replied; the
    // second has not, and it is the one that gets refused.
    await tick();
    second.settle(failed("no webview"));
    await Promise.all([step, last, saved]);

    expect(vi.mocked(commands.updateSettings).mock.calls[0][0].zoom).toBe(150);
    expect(zoom()).toBe(150);
  });

  it("waits for a repeat of the size already on screen that is still out", async () => {
    const first = deferred<WindowReply>();
    vi.mocked(commands.windowSetZoom).mockReturnValueOnce(first.promise);

    // Ctrl + held at the ceiling: the first press moves, every repeat after
    // it asks for the size already on screen and returns at once.
    const moved = useSettingsStore.getState().setZoom(150);
    const repeat = useSettingsStore.getState().setZoom(150);
    const saved = useSettingsStore.getState().saveZoom();
    first.settle(failed("no webview"));
    await Promise.all([moved, repeat, saved]);

    // The refused size never reaches the file; the rolled-back one does.
    expect(vi.mocked(commands.updateSettings).mock.calls[0][0].zoom).toBe(100);
    expect(zoom()).toBe(100);
  });

  /// Two presses in flight and both refused: the second must not fall back
  /// to the first, which the window never took either.

  it("puts back the size the window is showing, not the one it also refused", async () => {
    const first = deferred<WindowReply>();
    const second = deferred<WindowReply>();
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
    expect(vi.mocked(commands.updateSettings).mock.calls[0][0].zoom).toBe(100);
  });

  /// The replies can come back in either order. A newer press refused
  /// before an older one is accepted rolls the store past a size the window
  /// then lands on, and the store has to be brought back to it.

  it("follows a late success the window ended up on", async () => {
    const older = deferred<WindowReply>();
    const newer = deferred<WindowReply>();
    vi.mocked(commands.windowSetZoom)
      .mockReturnValueOnce(older.promise)
      .mockReturnValueOnce(newer.promise);

    const step = useSettingsStore.getState().setZoom(150);
    const next = useSettingsStore.getState().setZoom(160);
    newer.settle(failed("no webview"));
    await tick();
    older.settle(ok(null));
    await Promise.all([step, next]);
    await useSettingsStore.getState().saveZoom();

    expect(zoom()).toBe(150);
    expect(vi.mocked(commands.updateSettings).mock.calls[0][0].zoom).toBe(150);
  });

  /// The same two presses with the first accepted: the fall-back is then the
  /// size that press left on screen, not the one before it.

  it("puts back a size an earlier press had accepted", async () => {
    const first = deferred<WindowReply>();
    const second = deferred<WindowReply>();
    vi.mocked(commands.windowSetZoom)
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);

    const step = useSettingsStore.getState().setZoom(150);
    const next = useSettingsStore.getState().setZoom(160);
    first.settle(ok(null));
    await tick();
    second.settle(failed("no webview"));
    await Promise.all([step, next]);

    expect(zoom()).toBe(150);
  });

  it("never writes a size the window went on to refuse", async () => {
    const refusal = deferred<WindowReply>();
    vi.mocked(commands.windowSetZoom).mockReturnValueOnce(refusal.promise);

    useSettingsStore.setState({ settings: { ...settings, zoom: 150 } });

    // The commit goes out while the resize is still in flight, the way a
    // pointer release just after the last drag step does.
    const resized = useSettingsStore.getState().setZoom(160);
    const saved = useSettingsStore.getState().saveZoom();
    refusal.settle(failed("no webview"));
    await Promise.all([resized, saved]);

    // The commit still runs, but on the size the window is actually
    // showing: the refused one never reaches the file.
    expect(vi.mocked(commands.updateSettings).mock.calls[0][0].zoom).toBe(150);
    expect(zoom()).toBe(150);
  });
});
