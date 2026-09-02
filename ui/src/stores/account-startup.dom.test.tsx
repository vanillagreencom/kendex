// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useStartupLoads } from "@/App";
import { commands } from "@/bindings";
import { mount, settle } from "@/test/dom";
import { useAccountStore } from "./account";

vi.mock("@/bindings", () => ({
  commands: {
    accountStatus: vi.fn(),
    getSettings: vi.fn(),
    capabilityTable: vi.fn(),
    windowZoomState: vi.fn(),
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    updatesOverview: vi.fn(),
    appUpdateCheck: vi.fn(),
    appUpdateChannel: vi.fn(),
    appUpdateCommandChannel: vi.fn(),
    appVersion: vi.fn(),
  },
  ZOOM: { min: 50, max: 200, step: 10, default: 100 },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

function Startup() {
  useStartupLoads();
  return null;
}

describe("the account read on window focus", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useAccountStore.setState({ account: { kind: "loading" }, error: null });
    vi.mocked(commands.accountStatus).mockResolvedValue({
      status: "ok",
      data: { state: { state: "signed-out" }, endpoint: "https://kendex.ai" },
    } as Awaited<ReturnType<typeof commands.accountStatus>>);
    vi.mocked(commands.getSettings).mockResolvedValue({
      status: "ok",
      data: {
        settings: {
          schema: 1,
          appearance: "system",
          "harness-roots": {},
          projects: [],
          zoom: 100,
        },
        base: null,
      },
    } as unknown as Awaited<ReturnType<typeof commands.getSettings>>);
    vi.mocked(commands.capabilityTable).mockResolvedValue(
      [] as unknown as Awaited<ReturnType<typeof commands.capabilityTable>>,
    );
    vi.mocked(commands.windowZoomState).mockResolvedValue({
      percent: 100,
      launchRefused: false,
    });
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "ok",
      data: { harnesses: [], items: [], missingProjects: [], warnings: [] },
    });
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
    vi.mocked(commands.updatesOverview).mockResolvedValue({
      status: "ok",
      data: { rows: [], warnings: [], unreadable: [], lastFetched: null },
    });
    vi.mocked(commands.appUpdateCheck).mockResolvedValue({
      status: "error",
      error: "no feed in a test",
    } as Awaited<ReturnType<typeof commands.appUpdateCheck>>);
    vi.mocked(commands.appUpdateChannel).mockResolvedValue({
      status: "error",
      error: "no channel in a test",
    } as Awaited<ReturnType<typeof commands.appUpdateChannel>>);
    vi.mocked(commands.appUpdateCommandChannel).mockResolvedValue({
      status: "error",
      error: "no command channel in a test",
    } as Awaited<ReturnType<typeof commands.appUpdateCommandChannel>>);
    vi.mocked(commands.appVersion).mockResolvedValue(
      "0.0.0-test" as Awaited<ReturnType<typeof commands.appVersion>>,
    );
  });

  // A terminal can sign in or out while the window is away, and a read
  // that failed at launch would otherwise stand for the whole session.
  it("reads it again when the window comes back", async () => {
    vi.useFakeTimers();
    mount(<Startup />);
    await settle();
    expect(commands.accountStatus).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(6000);
    await act(async () => {
      window.dispatchEvent(new Event("focus"));
    });
    expect(commands.accountStatus).toHaveBeenCalledTimes(2);
    vi.useRealTimers();
  });
});
