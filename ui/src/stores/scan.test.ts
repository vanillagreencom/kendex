import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ScanResult } from "@/bindings";
import { commands } from "@/bindings";
import { useScanStore } from "./scan";

vi.mock("@/bindings", () => ({
  commands: {
    scanMachine: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn() },
}));

const emptyResult: ScanResult = {
  harnesses: [],
  items: [],
  missingProjects: [],
  warnings: [],
};

/** A scan this test answers by hand, to hold one open. */
const park = () => {
  let land: (value: ScanAnswer) => void = () => {};
  const promise = new Promise<ScanAnswer>((resolve) => {
    land = resolve;
  });
  return { promise, land };
};

type ScanAnswer = Awaited<ReturnType<typeof commands.scanMachine>>;

describe("scan store", () => {
  beforeEach(() => {
    useScanStore.setState({
      result: null,
      scanning: false,
      error: null,
      lastScanAt: null,
      backgroundFailureAnnounced: false,
    });
    vi.clearAllMocks();
  });

  it("stores the result on success and clears prior errors", async () => {
    useScanStore.setState({ error: "old failure" });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: emptyResult,
    });

    await useScanStore.getState().refresh();

    const state = useScanStore.getState();
    expect(state.result).toEqual(emptyResult);
    expect(state.error).toBeNull();
    expect(state.scanning).toBe(false);
  });

  it("stamps lastScanAt on a successful scan", async () => {
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: emptyResult,
    });

    await useScanStore.getState().refresh();

    expect(useScanStore.getState().lastScanAt).not.toBeNull();
  });

  it("leaves lastScanAt untouched when a scan fails", async () => {
    useScanStore.setState({ lastScanAt: 123 });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "error",
      error: "boom",
    });

    await useScanStore.getState().refresh();

    expect(useScanStore.getState().lastScanAt).toBe(123);
  });

  it("keeps the last good result when a rescan fails", async () => {
    useScanStore.setState({ result: emptyResult });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "error",
      error: "boom",
    });

    await useScanStore.getState().refresh();

    const state = useScanStore.getState();
    expect(state.result).toEqual(emptyResult);
    expect(state.error).toBe("boom");
  });

  // What this reverses: a request arriving mid-scan used to be dropped
  // outright — a silent no-op, nothing retrying — so the read behind a
  // write went missing whenever any background scan was out, and the write
  // is exactly what the scan already running cannot answer for. Home
  // renders its inventory from this result.
  it("takes a re-read behind a scan already running rather than dropping it", async () => {
    const parked = park();
    vi.mocked(commands.scanMachine)
      .mockReturnValueOnce(parked.promise)
      .mockResolvedValue({ status: "ok", data: emptyResult });

    const running = useScanStore.getState().refresh();
    const behind = useScanStore.getState().refresh();

    expect(commands.scanMachine).toHaveBeenCalledTimes(1);

    parked.land({ status: "ok", data: emptyResult });
    await running;
    await behind;

    expect(commands.scanMachine).toHaveBeenCalledTimes(2);
  });

  it("queues exactly one re-read however many arrive under the scan", async () => {
    const parked = park();
    vi.mocked(commands.scanMachine)
      .mockReturnValueOnce(parked.promise)
      .mockResolvedValue({ status: "ok", data: emptyResult });

    const running = useScanStore.getState().refresh();
    const behind = [
      useScanStore.getState().refresh(),
      useScanStore.getState().refresh(),
      useScanStore.getState().refresh(),
    ];

    parked.land({ status: "ok", data: emptyResult });
    await running;
    await Promise.all(behind);

    // Three arrivals, one re-read: they join it rather than stacking
    // identical whole-machine reads.
    expect(commands.scanMachine).toHaveBeenCalledTimes(2);
  });

  // A scan that could not answer is the state most in need of the one
  // behind it, and the slot has to be free again afterwards or the next
  // overlapping request would join a spent promise.
  it("re-reads behind a scan that failed, and again after that", async () => {
    const parked = park();
    vi.mocked(commands.scanMachine)
      .mockReturnValueOnce(parked.promise)
      .mockResolvedValue({ status: "ok", data: emptyResult });

    const running = useScanStore.getState().refresh();
    const behind = useScanStore.getState().refresh();
    parked.land({ status: "error", error: "ipc closed" });
    await running;
    await behind;

    expect(commands.scanMachine).toHaveBeenCalledTimes(2);

    const second = park();
    vi.mocked(commands.scanMachine).mockReturnValueOnce(second.promise);
    const again = useScanStore.getState().refresh();
    const alsoBehind = useScanStore.getState().refresh();
    second.land({ status: "ok", data: emptyResult });
    await again;
    await alsoBehind;

    expect(commands.scanMachine).toHaveBeenCalledTimes(4);
  });

  // The press's own `announce` dies with the slot's first queuer.
  it("speaks for a press that joined a scan queued by something else", async () => {
    useScanStore.setState({ backgroundFailureAnnounced: true });
    const parked = park();
    vi.mocked(commands.scanMachine)
      .mockReturnValueOnce(parked.promise)
      .mockResolvedValue({ status: "error", error: "the scan failed" });
    const out = useScanStore.getState().refresh();
    const silent = useScanStore.getState().refresh();
    const press = useScanStore.getState().refresh({ announce: true });
    parked.land({ status: "error", error: "the focus scan failed" });
    await Promise.all([out, silent, press]);
    expect(toast.error).toHaveBeenCalled();
  });

  it("toasts a background failure once, then stays quiet on repeat silent retries", async () => {
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "error",
      error: "boom",
    });

    await useScanStore.getState().refresh();
    await useScanStore.getState().refresh();

    expect(toast.error).toHaveBeenCalledTimes(1);
  });

  it("toasts every time a user-triggered refresh fails, announce or not", async () => {
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "error",
      error: "boom",
    });

    await useScanStore.getState().refresh({ announce: true });
    await useScanStore.getState().refresh({ announce: true });

    expect(toast.error).toHaveBeenCalledTimes(2);
  });

  it("re-arms the background toast after a scan succeeds", async () => {
    vi.mocked(commands.scanMachine).mockResolvedValueOnce({
      status: "error",
      error: "boom",
    });
    await useScanStore.getState().refresh();
    expect(toast.error).toHaveBeenCalledTimes(1);

    vi.mocked(commands.scanMachine).mockResolvedValueOnce({
      status: "ok",
      data: emptyResult,
    });
    await useScanStore.getState().refresh();

    vi.mocked(commands.scanMachine).mockResolvedValueOnce({
      status: "error",
      error: "boom again",
    });
    await useScanStore.getState().refresh();

    expect(toast.error).toHaveBeenCalledTimes(2);
  });

  // A rejected call used to escape the store entirely: no error, no
  // result, and Home read the silence as a scan still on its way.
  it("lands a rejected call as a failed scan, keeping the last result", async () => {
    useScanStore.setState({ result: emptyResult });
    vi.mocked(commands.scanMachine).mockRejectedValue(new Error("ipc down"));

    await useScanStore.getState().refresh();

    const state = useScanStore.getState();
    expect(state.error).toBe("ipc down");
    expect(state.result).toEqual(emptyResult);
    expect(state.scanning).toBe(false);
  });
});
