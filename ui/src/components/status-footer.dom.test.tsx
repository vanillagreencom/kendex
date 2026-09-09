// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, RowExits, ScanWarning, Scope } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { problemsFooterLabel } from "@/lib/error-copy";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
import { useScanStore } from "@/stores/scan";
import { mount, settle } from "@/test/dom";
import { StatusFooter } from "./status-footer";

vi.mock("@/bindings", () => ({
  commands: { auditAll: vi.fn(), scanMachine: vi.fn() },
}));
vi.mock("sonner", () => ({ toast: { error: vi.fn(), success: vi.fn() } }));

const ACME: Scope = { scope: "project", root: "/work/acme" };

const exits: RowExits[] = [
  {
    key: "skill:release-notes:claude",
    blocking: true,
    files: true,
    keep: true,
    enter: true,
    replace: true,
    tools: ["claude"],
  },
];

const blocked: AuditView = {
  scope: ACME,
  drift: [
    {
      kind: "skill",
      name: "release-notes",
      harness: "claude",
      scope: ACME,
      state: "conflict",
      cause: "unmanaged-content",
      detail: "/work/acme/.claude/skills/release-notes",
    },
  ],
  plan: [],
  notes: [],
  warnings: [],
  safety: [],
  adoptable: ADOPTABLE,
  exits,
};

const stage = (views: AuditView[]) =>
  act(() => {
    useAuditStore.setState({
      views,
      auditedAt: Date.now(),
      read: READ_LANDED,
    });
  });

const stageScan = (warnings: ScanWarning[]) =>
  act(() => {
    useScanStore.setState({
      result: { harnesses: [], items: [], missingProjects: [], warnings },
      error: null,
    });
  });

const emptyContainer = (
  path: string,
  standing: ScanWarning["standing"],
): ScanWarning => ({
  harness: "antigravity",
  kind: "mcp-server",
  path,
  problem: { kind: "empty-file" },
  standing,
});

beforeEach(() => {
  useAuditStore.setState({
    views: [],
    auditedAt: null,
    read: READ_LANDED,
  });
  useScanStore.setState({ result: null, error: null });
});

// The footer is the only thing outside the Problems page that says a
// declaration is waiting on a decision. Counting problems alone would let
// the one state this feature exists for pass unmentioned everywhere but
// the page nothing links to.
describe("what the footer counts as waiting", () => {
  it("counts a blocked declaration with no problem beside it", async () => {
    stage([blocked]);
    const host = mount(<StatusFooter />);
    await settle();

    expect(host.textContent).toContain(problemsFooterLabel(1));
  });

  // The count is what the reader sees from every page, so a file core
  // marked as information has to leave it alone: two empty containers, one
  // of them work, is one problem.
  it("counts only the files that need a repair", async () => {
    stage([{ ...blocked, drift: [], exits: [] }]);
    stageScan([
      emptyContainer("/h/.gemini/config/mcp_config.json", "actionable"),
      emptyContainer("/h/.codex/config.toml", "unused-empty-container"),
    ]);
    const host = mount(<StatusFooter />);
    await settle();

    expect(host.textContent).toContain(problemsFooterLabel(1));
  });

  // The control: nothing waiting means no count and nothing to press.
  it("says nothing when no place is blocked", async () => {
    stage([{ ...blocked, drift: [], exits: [] }]);
    const host = mount(<StatusFooter />);
    await settle();

    expect(host.textContent).not.toContain(problemsFooterLabel(1));
    expect(host.querySelectorAll("button")).toHaveLength(0);
  });
});
