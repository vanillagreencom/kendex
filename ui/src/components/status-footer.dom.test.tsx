// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, RowExits, Scope } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { problemsFooterLabel } from "@/lib/error-copy";
import { READ_LANDED } from "@/lib/read-state";
import { useAuditStore } from "@/stores/audit";
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

beforeEach(() => {
  useAuditStore.setState({
    views: [],
    auditedAt: null,
    read: READ_LANDED,
  });
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

  // The control: nothing waiting means no count and nothing to press.
  it("says nothing when no place is blocked", async () => {
    stage([{ ...blocked, drift: [], exits: [] }]);
    const host = mount(<StatusFooter />);
    await settle();

    expect(host.textContent).not.toContain(problemsFooterLabel(1));
    expect(host.querySelectorAll("button")).toHaveLength(0);
  });
});
