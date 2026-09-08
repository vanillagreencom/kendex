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
    expect(state.lastScanAt).not.toBeNull();
  });

  it("keeps the last result and its date when a scan fails", async () => {
    useScanStore.setState({ result: emptyResult, lastScanAt: 123 });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "error",
      error: "boom",
    });
    await useScanStore.getState().refresh();
    const state = useScanStore.getState();
    expect(state.result).toEqual(emptyResult);
    expect(state.error).toBe("boom");
    expect(state.lastScanAt).toBe(123);
  });

  // A request arriving mid-scan dropped outright — a silent no-op, nothing
  // retrying — would leave the read behind a write missing whenever any
  // background scan was out, and the write is exactly what the scan already
  // running cannot answer for. Home renders its inventory from this result.
  it("queues one re-read for arrivals during a running scan", async () => {
    const rows = [
      { name: "one arrival", arrivals: 1 },
      { name: "repeated arrivals", arrivals: 3 },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      vi.mocked(commands.scanMachine).mockClear();
      const parked = park();
      vi.mocked(commands.scanMachine)
        .mockReturnValueOnce(parked.promise)
        .mockResolvedValue({ status: "ok", data: emptyResult });
      const running = useScanStore.getState().refresh();
      const behind = Array.from({ length: row.arrivals }, () =>
        useScanStore.getState().refresh(),
      );
      expect(commands.scanMachine, row.name).toHaveBeenCalledTimes(1);
      parked.land({ status: "ok", data: emptyResult });
      await running;
      await Promise.all(behind);
      expect(commands.scanMachine, row.name).toHaveBeenCalledTimes(2);
    }
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

  it("announces each requested failure and only the first silent failure", async () => {
    const rows = [
      { name: "silent retries", announce: false, calls: 1 },
      { name: "user refreshes", announce: true, calls: 2 },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      useScanStore.setState({ backgroundFailureAnnounced: false });
      vi.mocked(toast.error).mockClear();
      vi.mocked(commands.scanMachine).mockResolvedValue({
        status: "error",
        error: "boom",
      });
      await useScanStore.getState().refresh({ announce: row.announce });
      await useScanStore.getState().refresh({ announce: row.announce });
      expect(toast.error, row.name).toHaveBeenCalledTimes(row.calls);
    }
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

  // A rejected call that escaped the store would leave no error and no
  // result, and Home reads that silence as a scan still on its way.
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
