// @vitest-environment jsdom
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useStartupLoads } from "@/App";
import { commands } from "@/bindings";
import { AccountSection } from "@/components/account-section";
import { MineTab } from "@/components/marketplaces/mine-tab";
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
    mineList: vi.fn(),
  },
  ZOOM: { min: 50, max: 200, step: 10, default: 100 },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

function Startup() {
  useStartupLoads();
  return null;
}

// The account read belongs to startup: a surface that shows sign-in state
// subscribes to what it found. Every surface firing its own load is the
// duplicate-fetch pattern this replaced.
describe("who reads the account", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useAccountStore.setState({ account: { kind: "loading" }, error: null });
    vi.mocked(commands.accountStatus).mockResolvedValue({
      status: "ok",
      data: { signedIn: false, endpoint: "https://kendex.ai" },
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
      data: { rows: [], warnings: [] },
    });
    vi.mocked(commands.mineList).mockResolvedValue({ status: "ok", data: [] });
  });

  it("reads it once no matter how many surfaces are on screen", async () => {
    mount(
      <>
        <Startup />
        <AccountSection />
        <MineTab />
      </>,
    );
    await settle();
    expect(commands.accountStatus).toHaveBeenCalledTimes(1);
  });

  it("does not read it for a surface mounted on its own", async () => {
    mount(
      <>
        <AccountSection />
        <MineTab />
      </>,
    );
    await settle();
    expect(commands.accountStatus).not.toHaveBeenCalled();
  });
});
