// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, ItemSafety, Scope } from "@/bindings";
import { commands } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { SAFETY_CHECK_FAILED, SAFETY_RETRY_LABEL } from "@/lib/copy-safety";
import { SEVERITY_LABELS } from "@/lib/labels";
import { useAuditStore } from "@/stores/audit";
import { refreshDownstream } from "@/stores/marketplaces-shared";
import { useScanStore } from "@/stores/scan";
import { mount, settle } from "@/test/dom";
import { PackageSafety } from "./package-safety";

vi.mock("@/bindings", () => ({
  commands: { auditAll: vi.fn(), scanMachine: vi.fn() },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const GLOBAL: Scope = { scope: "global" };

const gh: ItemSafety = {
  kind: "skill",
  name: "gh",
  harness: "claude",
  scope: GLOBAL,
  location: "",
  findings: [
    {
      rule: "dangerous-commands",
      severity: "high",
      location: "SKILL.md:20",
      message: "runs a shell command that deletes files without asking",
      remediation: "scope the command to a specific path, or drop it",
    },
  ],
  skipped: [],
  safety: { score: 58, deductions: [] },
  quality: null,
  ruleset: 3,
};

const view = (safety: ItemSafety[]): AuditView => ({
  scope: GLOBAL,
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety,
  adoptable: ADOPTABLE,
  exits: [],
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.scanMachine).mockResolvedValue({
    status: "ok",
    data: {
      items: [],
      harnesses: [],
      warnings: [],
      missingProjects: [],
    } as never,
  });
  useScanStore.setState({ scanning: false, result: null, error: null });
  useAuditStore.setState({
    views: [],
    auditing: false,
    auditedAt: null,
    error: null,
    checkError: null,
    backgroundFailureAnnounced: false,
  });
});

// An install writes the very bytes a score answers for. The audit that ran
// a moment earlier knows nothing about the new package, so a page opened on
// it has no row — and a block that renders nothing there reads as a package
// the check found nothing in, which is the one claim it has not made.
describe("a package installed just now", () => {
  it("shows its score, with the audit's freshness window already open", async () => {
    // The state right after any earlier visit: a clean audit, well inside
    // the window that would otherwise answer for this one.
    act(() => {
      useAuditStore.setState({ views: [view([])], auditedAt: Date.now() });
    });
    vi.mocked(commands.auditAll).mockResolvedValue({
      status: "ok",
      data: [view([gh])],
    });

    const host = mount(
      <PackageSafety
        reference={{ kind: "skill", name: "gh", scope: GLOBAL }}
      />,
    );
    await settle();
    expect(host.textContent).not.toContain("58/100");

    // What marketplaces.install ends with.
    await act(async () => {
      await refreshDownstream();
    });

    expect(host.textContent).toContain("58/100");
    expect(host.textContent).toContain(SEVERITY_LABELS.high);
    expect(host.textContent).toContain("SKILL.md:20");
  });
});

// A failed check is an outcome, not a wait. Rendering nothing for it leaves
// the page silent about a package it has never read, and the toast that
// announced the failure is gone by the time anybody looks.
describe("when the check could not run", () => {
  it("says so, with the way to ask again, instead of rendering nothing", async () => {
    act(() => {
      useAuditStore.setState({
        auditedAt: null,
        checkError: "audit crashed",
        backgroundFailureAnnounced: true,
      });
    });
    // The mount asks for a fresh audit, and it fails the same way. Only the
    // person pressing the button gets a different answer.
    vi.mocked(commands.auditAll)
      .mockResolvedValueOnce({ status: "error", error: "audit crashed" })
      .mockResolvedValue({ status: "ok", data: [view([gh])] });

    const host = mount(
      <PackageSafety
        reference={{ kind: "skill", name: "gh", scope: GLOBAL }}
      />,
    );
    await settle();

    expect(host.textContent).toContain(SAFETY_CHECK_FAILED);
    expect(host.textContent).toContain("audit crashed");

    const retry = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === SAFETY_RETRY_LABEL,
    );
    if (!retry) throw new Error("expected a retry button");
    await act(async () => {
      retry.click();
    });
    await settle();

    expect(host.textContent).toContain("58/100");
  });

  it("marks a reading kept from before the failure, never as the current one", async () => {
    act(() => {
      useAuditStore.setState({
        views: [view([gh])],
        auditedAt: Date.now(),
        checkError: "audit crashed",
      });
    });

    const host = mount(
      <PackageSafety
        reference={{ kind: "skill", name: "gh", scope: GLOBAL }}
      />,
    );
    await settle();

    expect(host.textContent).toContain("58/100");
    expect(host.textContent).toContain("couldn't run");
    expect(host.textContent).toContain(SAFETY_RETRY_LABEL);
  });
});
