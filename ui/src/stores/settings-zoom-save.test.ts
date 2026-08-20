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
