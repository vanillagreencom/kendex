import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { useAuditStore } from "./audit";
import { useProblemsStore } from "./problems";

vi.mock("@/bindings", () => ({
  commands: {
    auditAll: vi.fn(),
    applyPlan: vi.fn(),
    adoptItem: vi.fn(),
    toggleItem: vi.fn(),
    removeItem: vi.fn(),
  },
}));

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn() },
}));

vi.mock("./scan", () => ({
  useScanStore: { getState: () => ({ refresh: vi.fn() }) },
}));

const globalScope = { scope: "global" as const };

const emptyView: AuditView = {
  scope: globalScope,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  keepable: [],
  heldBack: [],
  queued: [],
};

describe("audit store refresh", () => {
  beforeEach(() => {
    useAuditStore.setState({
      views: [],
      auditing: false,
      error: null,
      busy: false,
      auditedAt: null,
      backgroundFailureAnnounced: false,
    });
    vi.clearAllMocks();
  });

  it("toasts a background audit failure once, not on every silent retry", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "error",
      error: "boom",
    });

    await useAuditStore.getState().refresh();
    await useAuditStore.getState().refresh();

    expect(toast.error).toHaveBeenCalledTimes(1);
  });

  it("re-arms the toast after a successful audit", async () => {
    vi.mocked(commands.auditAll).mockResolvedValueOnce({
      status: "error",
      error: "boom",
    });
    await useAuditStore.getState().refresh();

    vi.mocked(commands.auditAll).mockResolvedValueOnce({
      status: "ok",
      data: [],
    });
    await useAuditStore.getState().refresh();

    vi.mocked(commands.auditAll).mockResolvedValueOnce({
      status: "error",
      error: "boom again",
    });
    await useAuditStore.getState().refresh({ force: true });

    expect(toast.error).toHaveBeenCalledTimes(2);
  });

  it("reuses a recent audit instead of re-running it on every visit", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await useAuditStore.getState().refresh();
    await useAuditStore.getState().refresh();

    expect(commands.auditAll).toHaveBeenCalledTimes(1);
  });

  it("re-runs an audit the caller asks for by name", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({ status: "ok", data: [] });

    await useAuditStore.getState().refresh();
    await useAuditStore.getState().refresh({ force: true });

    expect(commands.auditAll).toHaveBeenCalledTimes(2);
  });

  it("does not toast on a successful audit", async () => {
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [],
    });

    await useAuditStore.getState().refresh();

    expect(toast.error).not.toHaveBeenCalled();
  });
});

describe("audit store run() actions", () => {
  beforeEach(() => {
    useAuditStore.setState({
      views: [emptyView],
      auditing: false,
      error: null,
      busy: false,
      auditedAt: null,
      backgroundFailureAnnounced: false,
    });
    useProblemsStore.setState({
      dialog: { open: false, title: "", steps: [], actions: [] },
    });
    vi.clearAllMocks();
  });

  it("shows the error modal with the backend message on an apply failure, not silently", async () => {
    vi.mocked(commands.applyPlan).mockResolvedValue({
      status: "error",
      error: "disk is full",
    });

    await useAuditStore.getState().applyPlan(globalScope, false);

    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe("Couldn't apply these changes");
    expect(dialog.message).toBe("disk is full");
    expect(useAuditStore.getState().error).toBe("disk is full");
    expect(toast.error).not.toHaveBeenCalled();
  });

  it("shows the error modal with the backend message on an adopt failure", async () => {
    vi.mocked(commands.adoptItem).mockResolvedValue({
      status: "error",
      error: "permission denied",
    });

    await useAuditStore
      .getState()
      .adopt(globalScope, "hook", "lint", ["claude"]);

    const dialog = useProblemsStore.getState().dialog;
    expect(dialog.open).toBe(true);
    expect(dialog.title).toBe("Couldn't start managing lint");
    expect(dialog.message).toBe("permission denied");
    expect(toast.success).not.toHaveBeenCalled();
  });

  it("toasts a success message when adopting an item", async () => {
    vi.mocked(commands.adoptItem).mockResolvedValue({
      status: "ok",
      data: emptyView,
    });

    await useAuditStore
      .getState()
      .adopt(globalScope, "hook", "lint", ["claude"]);

    expect(toast.success).toHaveBeenCalledWith("Now managing lint");
    expect(toast.error).not.toHaveBeenCalled();
  });

  it("does not toast success for a silent action like applying a plan", async () => {
    vi.mocked(commands.applyPlan).mockResolvedValue({
      status: "ok",
      data: emptyView,
    });

    await useAuditStore.getState().applyPlan(globalScope, false);

    expect(toast.success).not.toHaveBeenCalled();
  });
});

describe("applyPlan", () => {
  beforeEach(() => {
    useAuditStore.setState({
      views: [emptyView],
      auditing: false,
      error: null,
      busy: false,
      auditedAt: null,
      backgroundFailureAnnounced: false,
    });
    vi.clearAllMocks();
  });

  it("passes the accepted-findings tokens through to the backend", async () => {
    vi.mocked(commands.applyPlan).mockResolvedValue({
      status: "ok",
      data: emptyView,
    });

    await useAuditStore
      .getState()
      .applyPlan(globalScope, false, ["scraper@a1b2c3d4e5f6"]);

    expect(commands.applyPlan).toHaveBeenCalledWith(globalScope, false, [
      "scraper@a1b2c3d4e5f6",
    ]);
  });

  it("a rejected acceptance surfaces as an error, never a silent success", async () => {
    vi.mocked(commands.applyPlan).mockResolvedValue({
      status: "error",
      error: "'scraper' changed since its findings were read",
    });

    await useAuditStore
      .getState()
      .applyPlan(globalScope, false, ["scraper@a1b2c3d4e5f6"]);

    expect(useProblemsStore.getState().dialog.open).toBe(true);
    expect(useProblemsStore.getState().dialog.message).toContain(
      "changed since",
    );
    expect(toast.success).not.toHaveBeenCalled();
  });
});
