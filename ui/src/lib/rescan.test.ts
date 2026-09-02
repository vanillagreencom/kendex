import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { READ_LANDED } from "@/lib/read-state";
import { rescanEverything } from "@/lib/rescan";
import { useAuditStore } from "@/stores/audit";
import { useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";

vi.mock("@/bindings", () => ({
  commands: {
    scanMachine: vi.fn(),
    auditAll: vi.fn(),
    libraryProvenance: vi.fn(),
  },
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
  vi.mocked(commands.libraryProvenance).mockResolvedValue({
    status: "ok",
    data: [],
  });
  useProvenanceStore.setState({ rows: [], loaded: false });
  useScanStore.setState({
    scanning: false,
    result: null,
    error: null,
    backgroundFailureAnnounced: false,
  });
  useAuditStore.setState({
    views: [],
    auditing: false,
    auditedAt: null,
    error: null,
    read: READ_LANDED,
  });
});

describe("Scan again", () => {
  it("reads the machine and scores it again, not one without the other", async () => {
    await rescanEverything();

    expect(commands.scanMachine).toHaveBeenCalledTimes(1);
    expect(commands.auditAll).toHaveBeenCalledTimes(1);
  });

  // The third standing read. Every reader of the join used to guess when
  // something might have installed, and each guess missed a route — an
  // install redirected into another project being the one that got through
  // twice. Reading it here is what makes the guesses unnecessary: a write
  // that already asks for a rescan refreshes where things came from too.
  it("reads where every installation came from, alongside the other two", async () => {
    vi.mocked(commands.libraryProvenance).mockResolvedValue({
      status: "ok",
      data: [
        {
          scope: { scope: "project", root: "/home/me/hyprtrade" },
          kind: "skill",
          name: "gh",
          harness: "claude",
          origin: { origin: "marketplace", source: "kendex", repo: "a/b" },
        },
      ] as never,
    });

    await rescanEverything();

    expect(commands.libraryProvenance).toHaveBeenCalledTimes(1);
    expect(useProvenanceStore.getState().rows).toHaveLength(1);
  });

  // Somebody clicking this has a reason to think something changed. The
  // audit's freshness window would otherwise answer from before whatever
  // that was, leaving every score on screen quoting the old bytes.
  it("forces the audit past its freshness window", async () => {
    useAuditStore.setState({ auditedAt: Date.now() });

    await rescanEverything();

    expect(commands.auditAll).toHaveBeenCalledTimes(1);
  });

  // A background scan toasts its failure once and then goes quiet, so a
  // machine that keeps failing does not nag. Somebody who pressed the
  // button is waiting on an answer, though: silence there reads as a scan
  // that worked. The three buttons offering this all say so.
  it("says the scan failed again for somebody who pressed the button", async () => {
    const { toast } = await import("sonner");
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "error",
      error: "the machine could not be read",
    });

    // Startup already met the failure and announced it.
    await useScanStore.getState().refresh();
    expect(toast.error).toHaveBeenCalledTimes(1);
    expect(useScanStore.getState().backgroundFailureAnnounced).toBe(true);

    await rescanEverything({ announce: true });

    expect(toast.error).toHaveBeenCalledTimes(2);
  });

  // The control: a rescan behind a write is nobody's question, and the
  // store's once-only notice is what keeps it from nagging.
  it("stays quiet behind a write once the failure has been announced", async () => {
    const { toast } = await import("sonner");
    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "error",
      error: "the machine could not be read",
    });

    await useScanStore.getState().refresh();
    expect(toast.error).toHaveBeenCalledTimes(1);

    await rescanEverything();

    expect(toast.error).toHaveBeenCalledTimes(1);
  });
});
