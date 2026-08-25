// @vitest-environment jsdom
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AuditView, Finding, ItemSafety, Severity } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { SAFETY_CAVEAT } from "@/lib/copy-safety";
import { SEVERITY_LABELS } from "@/lib/labels";
import { useAuditStore } from "@/stores/audit";
import { mount } from "@/test/dom";
import { InstalledScore } from "./installed-score";

vi.mock("@/bindings", () => ({ commands: { auditAll: vi.fn() } }));

const finding = (severity: Severity): Finding => ({
  rule: "dangerous-commands",
  severity,
  location: "SKILL.md:20",
  message: "runs a shell command that deletes files without asking",
  remediation: "scope the command to a specific path, or drop it",
});

const scored = (
  score: number,
  findings: Finding[],
  harness: ItemSafety["harness"] = "claude",
): ItemSafety => ({
  kind: "skill",
  name: "gh",
  harness,
  scope: { scope: "global" },
  location: "",
  findings,
  skipped: [],
  safety: { score, deductions: [] },
  quality: null,
  ruleset: 3,
});

const view = (safety: ItemSafety[]): AuditView => ({
  scope: { scope: "global" },
  drift: [],
  plan: [],
  notes: [],
  warnings: [],
  safety,
  adoptable: ADOPTABLE,
  exits: [],
});

const stage = (views: AuditView[], auditedAt: number | null = 1) =>
  act(() => {
    useAuditStore.setState({ views, auditedAt, checkError: null });
  });

const words = () =>
  document.querySelector('[data-slot="tooltip-trigger"]')?.textContent ?? "";

beforeEach(() => {
  useAuditStore.setState({ views: [], auditedAt: null, checkError: null });
});

describe("a package's installed score in a table row", () => {
  it("names the number as the copy on disk, not the one an update would earn", () => {
    stage([view([scored(62, [finding("high")])])]);
    mount(<InstalledScore kind="skill" name="gh" />);

    expect(words()).toContain("installed now");
    expect(words()).toContain("62/100");
    expect(words()).toContain(SEVERITY_LABELS.high);
    expect(words()).toContain(SAFETY_CAVEAT);
  });

  it("says no check has answered rather than showing a score it does not have", () => {
    mount(<InstalledScore kind="skill" name="gh" />);

    expect(words()).toContain("Not checked yet");
    expect(words()).not.toMatch(/\d+\/100/);
  });

  // The files can change under the app — an editor saves a skill, another
  // tool rewrites a hook — and the next audit is the only thing that knows.
  // A row still quoting the old number would be a claim about bytes nobody
  // has read since.
  it("follows the audit when the content changes outside the app", () => {
    stage([view([scored(100, [])])]);
    mount(<InstalledScore kind="skill" name="gh" />);
    expect(words()).toContain("100/100");

    stage([view([scored(30, [finding("critical")])])], 2);

    expect(words()).toContain("30/100");
    expect(words()).toContain(SEVERITY_LABELS.critical);
    expect(words()).not.toContain("100/100");
  });

  // kendex renders one skill's bytes at every tool's place, so five tools
  // are five rows of one reading. The row is about the package.
  it("folds one package's per-tool rows into a single reading", () => {
    stage([
      view([
        scored(100, [], "claude"),
        scored(45, [finding("high")], "codex"),
        scored(45, [finding("high")], "pi"),
      ]),
    ]);
    mount(<InstalledScore kind="skill" name="gh" />);

    expect(words()).toContain("45/100");
    expect(words()).toContain(SEVERITY_LABELS.high);
    expect(words()).not.toContain("100/100");
  });
});
