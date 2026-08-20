import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { useSettingsStore } from "./settings";
import {
  deferred,
  dialog,
  failed,
  freshZoomStore,
  ok,
  type Reply,
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

describe("zoom, on disk", () => {
  beforeEach(freshZoomStore);

  it("does not undo a newer size when an older save replies late", async () => {
    const first = deferred<Reply>();
    vi.mocked(commands.updateSettings).mockReturnValueOnce(first.promise);

    await useSettingsStore.getState().setZoom(150);
    const saved = useSettingsStore.getState().saveZoom();
    // Once 150 is on its way, the person moves on.
    await vi.waitFor(() => expect(commands.updateSettings).toHaveBeenCalled());
    await useSettingsStore.getState().setZoom(160);
    first.settle(ok({ ...settings, zoom: 150 }));
    await saved;

    expect(zoom()).toBe(160);
  });

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

  it("never has two saves in flight, and the last one writes what is on screen", async () => {
    const first = deferred<Reply>();
    let live = 0;
    let mostLive = 0;
    const count = async (reply: Promise<Reply>) => {
      live += 1;
      mostLive = Math.max(mostLive, live);
      const settled = await reply;
      live -= 1;
      return settled;
    };
    vi.mocked(commands.updateSettings)
      .mockImplementationOnce(() => count(first.promise))
      .mockImplementation((next) => count(Promise.resolve(ok(next))));

    await useSettingsStore.getState().setZoom(150);
    const saves = [
      useSettingsStore.getState().saveZoom(),
      useSettingsStore.getState().saveZoom(),
      useSettingsStore.getState().saveZoom(),
    ];
    // The size moves on while the first save is still out.
    await vi.waitFor(() => expect(commands.updateSettings).toHaveBeenCalled());
    await useSettingsStore.getState().setZoom(160);
    first.settle(ok({ ...settings, zoom: 150 }));
    await Promise.all(saves);

    expect(mostLive).toBe(1);
    // Three asks, two writes: the queued ones collapse into one follow-up,
    // which writes the size on screen by the time it runs.
    expect(commands.updateSettings).toHaveBeenCalledTimes(2);
    expect(vi.mocked(commands.updateSettings).mock.calls[1][0].zoom).toBe(160);
  });

  it("reports a bridge that throws instead of leaving the rejection to nobody", async () => {
    vi.mocked(commands.updateSettings).mockRejectedValue(
      new Error("no bridge"),
    );

    await useSettingsStore.getState().setZoom(150);
    await expect(
      useSettingsStore.getState().saveZoom(),
    ).resolves.toBeUndefined();

    expect(zoom()).toBe(150);
    expect(dialog().title).toBe("Couldn't save the zoom");
    expect(dialog().message).toContain("no bridge");
  });

  it("does not turn a reported write failure into a second write", async () => {
    vi.mocked(commands.updateSettings).mockRejectedValueOnce(
      new Error("no bridge"),
    );

    await useSettingsStore.getState().setZoom(150);
    await useSettingsStore.getState().saveZoom();

    // Reported, not quietly retried.
    expect(commands.updateSettings).toHaveBeenCalledTimes(1);
    expect(dialog().title).toBe("Couldn't save the zoom");

    // And the queue is not left armed behind it: the next commit is one
    // write, not two.
    await useSettingsStore.getState().setZoom(160);
    await useSettingsStore.getState().saveZoom();

    expect(commands.updateSettings).toHaveBeenCalledTimes(2);
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

  it("keeps a change made to another setting while the save was in flight", async () => {
    const reply = deferred<Reply>();
    vi.mocked(commands.updateSettings).mockReturnValueOnce(reply.promise);

    await useSettingsStore.getState().setZoom(150);
    const saved = useSettingsStore.getState().saveZoom();
    useSettingsStore.setState({
      settings: { ...settings, zoom: 150, appearance: "dark" },
    });
    reply.settle(ok({ ...settings, zoom: 150 }));
    await saved;

    expect(useSettingsStore.getState().settings?.appearance).toBe("dark");
    expect(zoom()).toBe(150);
  });

  it("leaves the size on screen when it cannot be saved, and says so", async () => {
    vi.mocked(commands.updateSettings).mockResolvedValue(
      failed("disk is full"),
    );

    await useSettingsStore.getState().setZoom(150);
    await useSettingsStore.getState().saveZoom();

    expect(zoom()).toBe(150);
    expect(dialog().title).toBe("Couldn't save the zoom");
    expect(dialog().message).toBe("disk is full");
  });
});
