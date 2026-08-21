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
  stored,
  type WindowReply,
  type ZoomReply,
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

describe("zoom, on disk", () => {
  beforeEach(freshZoomStore);

  it("does not undo a newer size when an older save replies late", async () => {
    const first = deferred<ZoomReply>();
    vi.mocked(commands.saveZoom).mockReturnValueOnce(first.promise);

    await useSettingsStore.getState().setZoom(150);
    const saved = useSettingsStore.getState().saveZoom();
    // Once 150 is on its way, the person moves on.
    await vi.waitFor(() => expect(commands.saveZoom).toHaveBeenCalled());
    await useSettingsStore.getState().setZoom(160);
    first.settle(ok(150));
    await saved;

    expect(zoom()).toBe(160);
  });

  it("never has two saves in flight, and the last one writes what is on screen", async () => {
    const first = deferred<ZoomReply>();
    let live = 0;
    let mostLive = 0;
    const count = async (reply: Promise<ZoomReply>) => {
      live += 1;
      mostLive = Math.max(mostLive, live);
      const settled = await reply;
      live -= 1;
      return settled;
    };
    vi.mocked(commands.saveZoom)
      .mockImplementationOnce(() => count(first.promise))
      .mockImplementation((percent) => count(Promise.resolve(ok(percent))));

    await useSettingsStore.getState().setZoom(150);
    const saves = [
      useSettingsStore.getState().saveZoom(),
      useSettingsStore.getState().saveZoom(),
      useSettingsStore.getState().saveZoom(),
    ];
    // The size moves on while the first save is still out.
    await vi.waitFor(() => expect(commands.saveZoom).toHaveBeenCalled());
    await useSettingsStore.getState().setZoom(160);
    first.settle(ok(150));
    await Promise.all(saves);

    expect(mostLive).toBe(1);
    // Three asks, two writes: the queued ones collapse into one follow-up,
    // which writes the size on screen by the time it runs.
    expect(commands.saveZoom).toHaveBeenCalledTimes(2);
    expect(vi.mocked(commands.saveZoom).mock.calls[1][0]).toBe(160);
  });

  it("reports a bridge that throws instead of leaving the rejection to nobody", async () => {
    vi.mocked(commands.saveZoom).mockRejectedValue(new Error("no bridge"));

    await useSettingsStore.getState().setZoom(150);
    await expect(
      useSettingsStore.getState().saveZoom(),
    ).resolves.toBeUndefined();

    expect(zoom()).toBe(150);
    expect(dialog().title).toBe("Couldn't save the zoom");
    expect(dialog().message).toContain("no bridge");
  });

  it("does not turn a reported write failure into a second write", async () => {
    vi.mocked(commands.saveZoom).mockRejectedValueOnce(new Error("no bridge"));

    await useSettingsStore.getState().setZoom(150);
    await useSettingsStore.getState().saveZoom();

    // Reported, not quietly retried.
    expect(commands.saveZoom).toHaveBeenCalledTimes(1);
    expect(dialog().title).toBe("Couldn't save the zoom");

    // And the queue is not left armed behind it: the next commit is one
    // write, not two.
    await useSettingsStore.getState().setZoom(160);
    await useSettingsStore.getState().saveZoom();

    expect(commands.saveZoom).toHaveBeenCalledTimes(2);
  });

  /// The size goes to the file on its own. A whole-settings write would
  /// carry every other field as this commit read them, and a change made to
  /// one of them meanwhile would be carried back with it.
  it("writes the size without writing anything else", async () => {
    await useSettingsStore.getState().setZoom(150);
    await useSettingsStore.getState().saveZoom();

    expect(commands.saveZoom).toHaveBeenCalledWith(150);
    expect(commands.updateSettings).not.toHaveBeenCalled();
  });

  /// Every settings action writes the whole object, so a size that is only
  /// on screen would be persisted by an unrelated one — faithfully, and
  /// then rolled back on screen but not in the file, leaving the next
  /// launch to apply a size the window had refused.
  it("keeps a size the window has not answered for out of another setting's save", async () => {
    const asked = deferred<WindowReply>();
    vi.mocked(commands.windowSetZoom).mockReturnValueOnce(asked.promise);

    const previewed = useSettingsStore.getState().setZoom(150);
    await useSettingsStore.getState().setAppearance("dark");
    // Read while the resize is still out; asserted after it is answered, so
    // a failure here cannot leave the queue holding an unsettled request
    // for the rest of the suite.
    const carried = vi.mocked(commands.updateSettings).mock.calls[0][0].zoom;
    const onDisk = stored();

    asked.settle(failed("no webview"));
    await previewed;

    expect(carried).toBe(100);
    expect(onDisk).toBe(100);
    // The window never left 100, and neither did the file.
    expect(zoom()).toBe(100);
    expect(stored()).toBe(100);
  });

  /// The mirror of that: a settings action replies with the whole file as
  /// it read it, which may be older than the size the window has since
  /// taken. Reading the size to save out of that object would write the
  /// older one and lose the resize at the next launch.
  it("saves the size the window took, not the one an older reply put back", async () => {
    const theme = deferred<Reply>();
    vi.mocked(commands.updateSettings).mockReturnValueOnce(theme.promise);

    // The theme save reads the settings at 100% and is still out when the
    // person zooms.
    const themed = useSettingsStore.getState().setAppearance("dark");
    await useSettingsStore.getState().setZoom(150);
    theme.settle(ok({ ...settings, appearance: "dark", zoom: 100 }));
    await themed;

    expect(stored()).toBe(100);

    await useSettingsStore.getState().saveZoom();

    expect(commands.saveZoom).toHaveBeenCalledWith(150);
    expect(zoom()).toBe(150);
  });

  it("leaves the size on screen when it cannot be saved, and says so", async () => {
    vi.mocked(commands.saveZoom).mockResolvedValue(failed("disk is full"));

    await useSettingsStore.getState().setZoom(150);
    await useSettingsStore.getState().saveZoom();

    expect(zoom()).toBe(150);
    expect(dialog().title).toBe("Couldn't save the zoom");
    expect(dialog().message).toBe("disk is full");
  });
});
