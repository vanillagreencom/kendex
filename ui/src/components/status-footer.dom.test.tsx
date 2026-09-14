// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, RowExits, ScanWarning, Scope } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { attentionFooterLabel } from "@/lib/error-copy";
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
const OTHER: Scope = { scope: "project", root: "/work/other" };

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
  {
    key: "skill:changelog:claude",
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
    {
      kind: "skill",
      name: "changelog",
      harness: "claude",
      scope: ACME,
      state: "conflict",
      cause: "unmanaged-content",
      detail: "/work/acme/.claude/skills/changelog",
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
      result: {
        harnesses: [],
        items: [],
        missingProjects: [],
        readProjects: [],
        warnings,
      },
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

/** A place kendex could not read: a Problem with a card of its own. */
const unreadablePlace: AuditView = {
  ...blocked,
  scope: OTHER,
  drift: [],
  exits: [],
  error: { kind: "lock-corrupt", message: "lock unreadable" },
};

const marker = (host: HTMLElement) => host.querySelector("button");

// The marker counts what the Problems page holds, one per item it draws, in
// the tone of the most severe: red for any Problem, orange for Decisions
// alone. A place blocked on two declarations is one card, so one item.
describe("the footer marker", () => {
  it("counts Problems and Decisions per item, red while a Problem stands", async () => {
    stage([blocked, unreadablePlace]);
    const host = mount(<StatusFooter />);
    await settle();

    expect(marker(host)?.textContent).toBe(attentionFooterLabel(1, 1));
    expect(marker(host)?.className).toContain("text-critical");
  });

  it("is orange when only Decisions wait", async () => {
    stage([blocked]);
    const host = mount(<StatusFooter />);
    await settle();

    expect(marker(host)?.textContent).toBe(attentionFooterLabel(0, 1));
    expect(marker(host)?.className).toContain("text-warning");
  });

  // A file core marked as information is a Notice: two empty containers,
  // one of them work, is one Problem.
  it("counts only the files that need a repair", async () => {
    stage([{ ...blocked, drift: [], exits: [] }]);
    stageScan([
      emptyContainer("/h/.gemini/config/mcp_config.json", "actionable"),
      emptyContainer("/h/.codex/config.toml", "unused-empty-container"),
    ]);
    const host = mount(<StatusFooter />);
    await settle();

    expect(marker(host)?.textContent).toBe(attentionFooterLabel(1, 0));
  });

  // The control: nothing waiting means no count and nothing to press.
  it("says nothing when nothing waits", async () => {
    stage([{ ...blocked, drift: [], exits: [] }]);
    const host = mount(<StatusFooter />);
    await settle();

    expect(host.querySelectorAll("button")).toHaveLength(0);
  });
});

// A failed scan is a Problem whether or not an earlier result was kept, so
// its dot is red either way.
describe("the footer scan dot", () => {
  it("wears the Problem tone after a failed scan", async () => {
    const cases = [
      { name: "over a kept result", lastScanAt: Date.now() },
      { name: "with no scan ever landed", lastScanAt: null },
    ];
    for (const { name, lastScanAt } of cases) {
      act(() => useScanStore.setState({ error: "scan refused", lastScanAt }));
      const host = mount(<StatusFooter />);
      await settle();
      const dot = host.querySelector("footer > span > span > span");
      expect(dot?.className, name).toContain("bg-critical");
    }
  });
});
