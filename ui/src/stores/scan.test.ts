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

  it("ignores refresh while a scan is already running", async () => {
    useScanStore.setState({ scanning: true });
    await useScanStore.getState().refresh();
    expect(commands.scanMachine).not.toHaveBeenCalled();
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
