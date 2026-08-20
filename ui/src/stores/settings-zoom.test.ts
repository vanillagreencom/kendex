import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AppSettings } from "@/bindings";
import { commands } from "@/bindings";
import { useProblemsStore } from "./problems";
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
  },
  ZOOM: { min: 50, max: 200, step: 10, default: 100 },
}));

vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const settings: AppSettings = {
  schema: 1,
  appearance: "system",
  safety: { "warn-below": 80, "block-below": 60 },
  "harness-roots": {},
  projects: [],
  zoom: 100,
};

type Reply =
  | { status: "ok"; data: AppSettings }
  | { status: "error"; error: string };

const ok = <T>(data: T) => ({ status: "ok" as const, data });
const failed = (error: string) => ({ status: "error" as const, error });

/** A promise whose settling this test decides. */
function deferred<T>() {
  let settle: (value: T) => void = () => {};
  const promise = new Promise<T>((resolve) => {
    settle = resolve;
  });
  return { promise, settle };
}

const zoom = () => useSettingsStore.getState().settings?.zoom;
const dialog = () => useProblemsStore.getState().dialog;

describe("zoom", () => {
  beforeEach(() => {
    useSettingsStore.setState({ settings, capabilities: [] });
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.clearAllMocks();
    vi.mocked(commands.windowSetZoom).mockResolvedValue(ok(null));
    vi.mocked(commands.updateSettings).mockImplementation(async (next) =>
      ok(next),
    );
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
    vi.mocked(commands.windowSetZoom).mockResolvedValue(failed("no webview"));

    await useSettingsStore.getState().setZoom(150);

    expect(zoom()).toBe(100);
    expect(commands.updateSettings).not.toHaveBeenCalled();
    expect(dialog().title).toBe("Couldn't change the zoom");
    expect(dialog().message).toBe("no webview");
  });

  it("does not undo a newer size when an older resize comes back refused", async () => {
    const first = deferred<ReturnType<typeof failed>>();
    vi.mocked(commands.windowSetZoom)
      .mockReturnValueOnce(first.promise)
      .mockResolvedValue(ok(null));

    const refused = useSettingsStore.getState().setZoom(150);
    await useSettingsStore.getState().setZoom(160);
    first.settle(failed("no webview"));
    await refused;

    expect(zoom()).toBe(160);
  });

  it("does not undo a newer size when an older save replies late", async () => {
    const first = deferred<Reply>();
    vi.mocked(commands.updateSettings).mockReturnValueOnce(first.promise);

    await useSettingsStore.getState().setZoom(150);
    const saved = useSettingsStore.getState().saveZoom();
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
    await useSettingsStore.getState().setZoom(160);
    first.settle(ok({ ...settings, zoom: 150 }));
    await Promise.all(saves);

    expect(mostLive).toBe(1);
    // Three asks, two writes: the queued ones collapse into one follow-up,
    // which writes the size on screen by the time it runs.
    expect(commands.updateSettings).toHaveBeenCalledTimes(2);
    expect(vi.mocked(commands.updateSettings).mock.calls[1][0].zoom).toBe(160);
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
