// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, DriftRow, ScanResult, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { unmanagedHereLabel } from "@/lib/copy";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { useScanStore } from "@/stores/scan";
import { useSettingsStore } from "@/stores/settings";
import { mount, settle } from "@/test/dom";
import { ProjectList } from "./project-list";

vi.mock("@/bindings", () => ({
  commands: {
    auditAll: vi.fn(),
    scanMachine: vi.fn(),
    registerProject: vi.fn(),
    unregisterProject: vi.fn(),
    discoverProjects: vi.fn(),
    getSettings: vi.fn(),
    capabilityTable: vi.fn(),
    updateSettings: vi.fn(),
    installDriftHook: vi.fn(),
  },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const ACME: Scope = { scope: "project", root: "/work/acme" };

const emptyScan: ScanResult = {
  items: [],
  harnesses: [],
  warnings: [],
  missingProjects: [],
};

const view = (scope: Scope, drift: DriftRow[]): AuditView => ({
  scope,
  drift,
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits: [],
});

const byHand = (name: string): DriftRow => ({
  kind: "skill",
  name,
  harness: "claude",
  state: "unmanaged",
  detail: `/work/acme/.claude/skills/${name}`,
  scope: ACME,
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: emptyScan as never,
  });
  useScanStore.setState({ scanning: false, result: emptyScan, error: null });
  useAuditStore.setState({
    views: [view({ scope: "global" }, [])],
    auditing: false,
    auditedAt: Date.now(),
    error: null,
    read: READ_LANDED,
    backgroundFailureAnnounced: false,
  });
  useSettingsStore.setState({ settings: { projects: [] } as never });
});

// The card's count is the app's only mention of unmanaged content, and the
// only way to the page that offers to take it on. A project registered while
// this page is open has no AuditView until something asks for one, and a
// scope with no view counts zero — so the card would hide the very items the
// new project holds.
describe("a project added while the list is on screen", () => {
  it("counts what it holds, without a revisit", async () => {
    vi.mocked(commands.registerProject).mockResolvedValue({
      status: "ok",
      data: { settings: { projects: ["/work/acme"] }, base: null } as never,
    });
    // The audit the registration forces is the one that first sees the
    // project at all.
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [
        view({ scope: "global" }, []),
        view(ACME, [byHand("gh"), byHand("lint")]),
      ],
    });

    const host = mount(<ProjectList />);
    await settle();
    expect(host.textContent).not.toContain(unmanagedHereLabel(2));

    await act(async () => {
      await useSettingsStore.getState().registerProject("/work/acme");
    });
    await settle();

    expect(commands.auditAll).toHaveBeenCalled();
    expect(host.textContent).toContain(unmanagedHereLabel(2));
  });

  // The mount's own audit is inside the freshness window by the time the
  // registration lands, so an unforced ask would return without calling the
  // backend at all and the count would stay at zero.
  it("asks past the freshness window rather than reusing the last answer", async () => {
    vi.mocked(commands.registerProject).mockResolvedValue({
      status: "ok",
      data: { settings: { projects: ["/work/acme"] }, base: null } as never,
    });
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [view(ACME, [byHand("gh")])],
    });

    mount(<ProjectList />);
    await settle();
    const beforeRegistering = vi.mocked(commands.auditAll).mock.calls.length;

    await act(async () => {
      await useSettingsStore.getState().registerProject("/work/acme");
    });

    expect(vi.mocked(commands.auditAll).mock.calls.length).toBeGreaterThan(
      beforeRegistering,
    );
  });
});
