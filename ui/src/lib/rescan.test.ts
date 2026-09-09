import { beforeEach, describe, expect, it, vi } from "vitest";
import { commands } from "@/bindings";
import { identityCurrent } from "@/lib/package-identity";
import { READ_LANDED } from "@/lib/read-state";
import { rescanEverything } from "@/lib/rescan";
import { useAuditStore } from "@/stores/audit";
import { joinCurrent, useProvenanceStore } from "@/stores/provenance";
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
  useProvenanceStore.setState({ rows: [], loaded: false, answeredFor: null });
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
    read: READ_LANDED,
  });
});

describe("Scan again", () => {
  // The third standing read. A reader of the join guessing when something
  // might have installed misses a route — an install redirected into
  // another project is the one that gets through. Reading it here is what
  // makes the guessing unnecessary: a write that already asks for a rescan
  // refreshes where things came from too.
  it("reads where every installation came from, alongside the other two", async () => {
    vi.mocked(commands.libraryProvenance).mockResolvedValue({
      status: "ok",
      data: [
        {
          scope: { scope: "project", root: "/home/me/hyprtrade" },
          kind: "skill",
          name: "gh",
          harness: "claude",
          at: null,
          origin: { origin: "marketplace", source: "kendex", repo: "a/b" },
        },
      ] as never,
    });

    await rescanEverything();

    expect(commands.scanMachine).toHaveBeenCalledTimes(1);
    expect(commands.auditAll).toHaveBeenCalledTimes(1);
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

// The scan and the identity join answer separately, and a rescan publishes
// the scan first. Read as "a join once landed", readiness would let every
// count and the package page's missing-package effect group a new scan
// against the previous answer — and that navigation is not undone by the
// later render. So readiness asks which scan the rows answer about.
describe("identity readiness across a rescan", () => {
  // Asked of the production rule, not a second copy of it here: a
  // readiness test that spelled the comparison itself would go on passing
  // whatever the app does.
  const known = () =>
    identityCurrent(
      useProvenanceStore.getState().answeredFor,
      useScanStore.getState().generation,
    );

  it("is not known for a scan the join has not answered about", async () => {
    await rescanEverything();
    expect(known()).toBe(true);

    // A scan lands on its own — a focus rescan's, or the read-back behind a
    // write — with no join behind it yet.
    await useScanStore.getState().refresh();
    expect(useScanStore.getState().result).not.toBeNull();
    expect(known()).toBe(false);

    // And is known again once the join has answered about that scan.
    await useProvenanceStore.getState().reload();
    expect(known()).toBe(true);
  });

  // The join answers about the machine as it was when the read began. One
  // that began before a scan landed says nothing about it.
  it("does not count a join that began before the scan it would answer for", async () => {
    await rescanEverything();
    const settle = useProvenanceStore.getState().reload();
    await useScanStore.getState().refresh();
    await settle;
    expect(known()).toBe(false);
  });
});

// A scan that failed leaves the previous result and its number standing.
// The join read after it would be stamped with that number and pass as an
// answer about a scan it never saw — new identity rows over old
// observations.
describe("the identity read behind a scan that failed", () => {
  it("is not asked for, and readiness stays what it was", async () => {
    await rescanEverything();
    const settled = useScanStore.getState().generation;
    vi.mocked(commands.libraryProvenance).mockClear();

    vi.mocked(commands.scanMachine).mockResolvedValue({
      status: "error",
      error: "the machine could not be read",
    });
    await rescanEverything();

    expect(useScanStore.getState().generation).toBe(settled);
    expect(vi.mocked(commands.libraryProvenance)).not.toHaveBeenCalled();
    expect(
      identityCurrent(
        useProvenanceStore.getState().answeredFor,
        useScanStore.getState().generation,
      ),
    ).toBe(true);
  });
});

// The predicate an irreversible action asks. A landed, idle read of the
// scan BEFORE this one is not an answer about what is on the page now.
describe("whether the join may be acted on", () => {
  it("is false for a landed read that answered about an older scan", async () => {
    await rescanEverything();
    expect(joinCurrent(useProvenanceStore.getState())).toBe(true);

    await useScanStore.getState().refresh();
    expect(joinCurrent(useProvenanceStore.getState())).toBe(false);

    await useProvenanceStore.getState().reload();
    expect(joinCurrent(useProvenanceStore.getState())).toBe(true);
  });
});
