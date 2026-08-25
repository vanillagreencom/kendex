import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { rescanEverything } from "@/lib/rescan";
import { useAuditStore } from "@/stores/audit";
import { useScanStore } from "@/stores/scan";

vi.mock("@/bindings", () => ({
  commands: { scanMachine: vi.fn(), auditAll: vi.fn() },
}));

vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const emptyScan = {
  items: [],
  harnesses: [],
  warnings: [],
  missingProjects: [],
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: emptyScan as never,
  });
  vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });
  useScanStore.setState({ scanning: false, result: null, error: null });
  useAuditStore.setState({
    views: [],
    auditing: false,
    auditedAt: null,
    error: null,
    checkError: null,
  });
});

describe("Scan again", () => {
  it("reads the machine and scores it again, not one without the other", async () => {
    await rescanEverything();

    expect(commands.scanMachine).toHaveBeenCalledTimes(1);
    expect(commands.auditAll).toHaveBeenCalledTimes(1);
  });

  // Somebody clicking this has a reason to think something changed. The
  // audit's freshness window would otherwise answer from before whatever
  // that was, leaving every score on screen quoting the old bytes.
  it("forces the audit past its freshness window", async () => {
    useAuditStore.setState({ auditedAt: Date.now() });

    await rescanEverything();

    expect(commands.auditAll).toHaveBeenCalledTimes(1);
  });
});
