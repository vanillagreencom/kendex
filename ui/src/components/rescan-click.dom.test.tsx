// @vitest-environment jsdom
// The buttons that offer to look again. A background scan toasts its
// failure once and then goes quiet, so a machine that keeps failing does
// not nag — but somebody who pressed a button is waiting on an answer, and
// silence there reads as a scan that worked. That only holds if the click
// path asks to be told, which is a thing about the call sites and not about
// `rescanEverything`: the option was inert for a whole round because every
// caller took the default.
import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { ProblemCard } from "@/components/problem-card";
import { Sidebar } from "@/components/sidebar";
import { SCAN_AGAIN_LABEL } from "@/lib/copy";
import { OverviewPage } from "@/pages/overview";
import { useMarketplacesStore } from "@/stores/marketplaces";
import { useScanStore } from "@/stores/scan";
import { mount, settle } from "@/test/dom";

vi.mock("@/bindings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@/bindings")>()),
  commands: {
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    // The third read a rescan makes. Stubbed rather than left off: absent,
    // it throws into the store's catch on every rescan and these tests run
    // a rescan that is quietly two thirds of one.
    libraryProvenance: vi.fn(async () => ({ status: "ok", data: [] })),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const failing = () =>
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "error",
    error: "the machine could not be read",
  });

const press = async (host: HTMLElement, label: string) => {
  const button = [...host.querySelectorAll("button")].find(
    (one) => one.textContent === label || one.getAttribute("title") === label,
  );
  if (!button) throw new Error(`no "${label}" button`);
  await settle();
  button.click();
  await settle();
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  // Home reads the marketplaces overview on mount. It is nothing to do
  // with the button under test, and a command still in flight when the
  // file's module registry comes down throws from a mock that is no longer
  // there — so the store's own read is stubbed out rather than mocked at
  // the command.
  useMarketplacesStore.setState({ load: async () => {} });
  useScanStore.setState({
    scanning: false,
    result: null,
    error: null,
    backgroundFailureAnnounced: false,
  });
});

describe("a button offering to look again", () => {
  it("is told about a failure the background scan already announced", async () => {
    const { toast } = await import("sonner");
    failing();
    // Startup met the failure and said so; the store has gone quiet.
    await useScanStore.getState().refresh();
    expect(toast.error).toHaveBeenCalledTimes(1);

    const host = mount(
      <ProblemCard
        problem={{
          key: "scan",
          kind: "scan-failure",
          message: "the machine could not be read",
          scope: null,
        }}
      />,
    );
    await press(host, "Rescan");

    expect(toast.error).toHaveBeenCalledTimes(2);
  });

  it("is told from the sidebar's Scan again too", async () => {
    const { toast } = await import("sonner");
    failing();
    await useScanStore.getState().refresh();
    expect(toast.error).toHaveBeenCalledTimes(1);

    const host = mount(<Sidebar />);
    await press(host, "Scan again");

    expect(toast.error).toHaveBeenCalledTimes(2);
  });

  it("is told from Home's Scan again too", async () => {
    const { toast } = await import("sonner");
    failing();
    await useScanStore.getState().refresh();
    expect(toast.error).toHaveBeenCalledTimes(1);

    const host = mount(<OverviewPage />);
    await press(host, SCAN_AGAIN_LABEL);

    expect(toast.error).toHaveBeenCalledTimes(2);
  });
});
