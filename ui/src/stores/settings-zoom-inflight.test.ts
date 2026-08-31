import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useSettingsStore } from "./settings";
import {
  deferred,
  dialog,
  failed,
  freshZoomStore,
  pendingResize,
  stored,
  tick,
  type WindowReply,
  windowAt,
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

describe("zoom, with a resize still out", () => {
  beforeEach(freshZoomStore);

  /// The commit boundary, driven the way the app drives it: `flush()` on a
  /// page going away calls `save()` with nothing settled, so the resize the
  /// last press made is still out. A commit that writes the size on screen
  /// writes one the window is about to refuse — the display rolls back, the
  /// file does not, and that size is what every later launch asks for.
  it("writes the size the window kept, not the one it was about to refuse", async () => {
    useSettingsStore.setState({ zoom: 150 });
    windowAt(150);
    const out = deferred<WindowReply>();
    vi.mocked(commands.windowSetZoom).mockReturnValueOnce(out.promise);

    const press = useSettingsStore.getState().setZoom(160);
    const saved = useSettingsStore.getState().saveZoom();
    out.settle(failed("no webview"));
    await Promise.all([press, saved]);

    expect(vi.mocked(commands.saveZoom).mock.calls[0][0]).toBe(150);
    expect(zoom()).toBe(150);
    expect(stored()).toBe(150);
  });

  /// A pointer release lands between a drag's last two steps, so a second
  /// resize joins after the commit has already started waiting. Waiting
  /// once is not enough: what settles the commit is that nothing new
  /// arrived while it waited.
  ///
  /// Both resizes are taken, which is what separates the two codepaths. A
  /// commit that waits once reads the window between the replies and writes
  /// the size the drag passed through; one that waits for nothing reads it
  /// before either reply and writes the size the drag started from.
  it("waits for a resize that starts while the commit is already waiting", async () => {
    const first = pendingResize(150);
    const second = pendingResize(160);

    const step = useSettingsStore.getState().setZoom(150);
    const saved = useSettingsStore.getState().saveZoom();
    const last = useSettingsStore.getState().setZoom(160);
    // The commit read `resizes` when it was called, so the press above
    // joined after it. Long enough here for a commit that waits for nothing
    // to have read the window already.
    await tick();
    first.takes();
    await tick();
    second.takes();
    await Promise.all([step, last, saved]);

    expect(vi.mocked(commands.saveZoom).mock.calls[0][0]).toBe(160);
    expect(zoom()).toBe(160);
  });

  /// The same shape with the joining resize refused: the window keeps the
  /// size the first press put it at, and the display follows it back.
  it("writes the size a refused joining resize left the window at", async () => {
    const first = pendingResize(150);
    const second = pendingResize(160);

    const step = useSettingsStore.getState().setZoom(150);
    const saved = useSettingsStore.getState().saveZoom();
    const last = useSettingsStore.getState().setZoom(160);
    await tick();
    first.takes();
    await tick();
    second.refuses("no webview");
    await Promise.all([step, last, saved]);

    expect(vi.mocked(commands.saveZoom).mock.calls[0][0]).toBe(150);
    expect(zoom()).toBe(150);
  });

  /// Ctrl + held at the ceiling: the first press moves the display, every
  /// repeat after it asks for the size already on screen and returns at
  /// once. The commit still has the first one to wait for, and reads the
  /// window only once it has replied.
  it("waits for a repeat of the size already on screen that is still out", async () => {
    const first = pendingResize(150);

    const moved = useSettingsStore.getState().setZoom(150);
    const repeat = useSettingsStore.getState().setZoom(150);
    const saved = useSettingsStore.getState().saveZoom();
    await tick();
    first.takes();
    await Promise.all([moved, repeat, saved]);

    expect(vi.mocked(commands.saveZoom).mock.calls[0][0]).toBe(150);
    expect(zoom()).toBe(150);
  });

  /// The window is the authority on the size, and a run that cannot read it
  /// has no authority to write from. Writing the display instead would
  /// write whatever the last press asked for — which is the refused size,
  /// because the rollback reads the same window and failed the same way.
  it("writes nothing when the window cannot say what size it is at", async () => {
    useSettingsStore.setState({ zoom: 150 });
    windowAt(150);
    vi.mocked(commands.windowSetZoom).mockResolvedValue(failed("no webview"));
    vi.mocked(commands.windowZoomState).mockRejectedValue(
      new Error("no bridge"),
    );

    await useSettingsStore.getState().setZoom(160);
    await useSettingsStore.getState().saveZoom();

    expect(commands.saveZoom).not.toHaveBeenCalled();
    expect(stored()).toBe(100);
    expect(dialog().title).toBe("Couldn't save the zoom");
  });
});
