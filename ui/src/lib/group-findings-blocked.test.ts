import { describe, expect, it } from "vitest";
import type { Finding, FindingDecision, ItemSafety } from "@/bindings";
import {
  acceptTokens,
  groupBlocked,
  groupFindingsByRule,
  mergeHeldBack,
} from "./group-findings-blocked";

const RULE_FINDING: Finding = {
  rule: "dangerous-commands",
  severity: "high",
  location: "/home/dana/skills/visual-qa/evals/grade.py:848",
  message: "runs a shell command built from unescaped input",
  remediation: "validate or escape the input before it reaches the shell",
};

function row(overrides: Partial<ItemSafety>): ItemSafety {
  return {
    kind: "skill",
    name: "visual-qa",
    harness: "codex",
    scope: { scope: "global" },
    safety: { score: 40, deductions: [] },
    quality: null,
    findings: [RULE_FINDING],
    skipped: [],
    verdict: "block",
    reasons: [],
    contentHash: "hash",
    reviewHash: "review-hash",
    location: "",
    provenance: null,
    decisions: [],
    override: { state: "absent" },
    ...overrides,
  };
}

describe("groupFindingsByRule", () => {
  it("collapses one rule firing at several locations into one entry", () => {
    const findings = [
      RULE_FINDING,
      {
        ...RULE_FINDING,
        location: "/home/dana/skills/visual-qa/process.py:89",
      },
      {
        ...RULE_FINDING,
        location: "/home/dana/skills/visual-qa/process.py:111",
      },
    ];
    const groups = groupFindingsByRule(findings, []);
    expect(groups).toHaveLength(1);
    expect(groups[0].locations).toEqual([
      RULE_FINDING.location,
      "/home/dana/skills/visual-qa/process.py:89",
      "/home/dana/skills/visual-qa/process.py:111",
    ]);
  });

  it("keeps rules with a different message or remediation apart", () => {
    const findings: Finding[] = [
      RULE_FINDING,
      { ...RULE_FINDING, message: "different message" },
      { ...RULE_FINDING, remediation: "different fix" },
    ];
    expect(groupFindingsByRule(findings, [])).toHaveLength(3);
  });

  it("keeps the highest severity across a rule's findings", () => {
    const findings: Finding[] = [
      { ...RULE_FINDING, severity: "medium" },
      { ...RULE_FINDING, severity: "critical" },
      { ...RULE_FINDING, severity: "low" },
    ];
    expect(groupFindingsByRule(findings, [])[0].severity).toBe("critical");
  });
});

describe("groupBlocked", () => {
  it("merges the same (kind, name) across harnesses when their finding sets are identical", () => {
    const codex = row({ harness: "codex" });
    const pi = row({ harness: "pi" });
    const groups = groupBlocked([codex, pi]);
    expect(groups).toHaveLength(1);
    expect(groups[0].rows.map((r) => r.harness)).toEqual(["codex", "pi"]);
  });

  it("does not merge the same (kind, name) across harnesses when their finding sets differ", () => {
    const codex = row({ harness: "codex" });
    const pi = row({
      harness: "pi",
      findings: [{ ...RULE_FINDING, location: "different-file.py:1" }],
    });
    const groups = groupBlocked([codex, pi]);
    expect(groups).toHaveLength(2);
  });

  it("groups the findings of a merged entry by rule", () => {
    const secondFinding: Finding = {
      rule: "rce",
      severity: "critical",
      location: "/home/dana/skills/visual-qa/evals/grade.py:12",
      message: "downloads a script from a URL and executes it directly",
      remediation:
        "pin and vendor the script instead of fetching it at runtime",
    };
    const codex = row({
      harness: "codex",
      findings: [RULE_FINDING, secondFinding],
    });
    const pi = row({ harness: "pi", findings: [RULE_FINDING, secondFinding] });
    const groups = groupBlocked([codex, pi]);
    expect(groups).toHaveLength(1);
    expect(groups[0].findingGroups.map((g) => g.rule)).toEqual([
      "dangerous-commands",
      "rce",
    ]);
  });

  it("keeps different names apart even with identical findings", () => {
    const a = row({ name: "visual-qa" });
    const b = row({ name: "other-skill" });
    expect(groupBlocked([a, b])).toHaveLength(2);
  });
});

describe("mergeHeldBack", () => {
  it("adds a fresh refusal the observed list cannot carry", () => {
    const fresh = row({ name: "brand-new" });
    const { display, plannedByItem, onDisk } = mergeHeldBack([], [fresh]);
    expect(display).toEqual([fresh]);
    expect(plannedByItem.get("skill::brand-new")).toEqual([fresh]);
    expect(onDisk.size).toBe(0);
  });

  it("does not render one item twice when it is both observed and planned", () => {
    const observed = row({ contentHash: "on-disk" });
    const planned = row({ contentHash: "would-write" });
    const { display, plannedByItem, onDisk } = mergeHeldBack(
      [observed],
      [planned],
    );
    expect(display).toEqual([observed]);
    expect(plannedByItem.get("skill::visual-qa")).toEqual([planned]);
    expect(onDisk.has("skill::visual-qa::codex")).toBe(true);
  });

  it("an unmanaged blocked item has no planned rows, so no accept action", () => {
    const { plannedByItem } = mergeHeldBack([row({})], []);
    expect(plannedByItem.size).toBe(0);
  });
});

describe("acceptTokens", () => {
  it("sends one token per distinct content, not per harness", () => {
    const codex = row({ harness: "codex", reviewHash: "aaaaaaaaaaaa9999" });
    const pi = row({ harness: "pi", reviewHash: "aaaaaaaaaaaa9999" });
    expect(acceptTokens([codex, pi])).toEqual(["visual-qa@aaaaaaaaaaaa"]);
  });

  it("divergent variants each get their own token", () => {
    const codex = row({ harness: "codex", reviewHash: "aaaaaaaaaaaa0000" });
    const pi = row({ harness: "pi", reviewHash: "bbbbbbbbbbbb0000" });
    expect(acceptTokens([codex, pi])).toEqual([
      "visual-qa@aaaaaaaaaaaa",
      "visual-qa@bbbbbbbbbbbb",
    ]);
  });

  it("keeps every finding on a held-back item, whatever was decided about it", () => {
    const other = {
      ...RULE_FINDING,
      rule: "supply-chain",
      location: "SKILL.md:9",
    };
    const held = row({
      findings: [RULE_FINDING, other],
      decisions: [
        {
          fingerprint: "a",
          token: "t1",
          state: {
            state: "dismissed",
            reason: "wrong-call",
            dismissedAt: "2026-08-16T00:00:00Z",
          },
        },
        {
          fingerprint: "b",
          token: "t2",
          state: { state: "open", earlier: null },
        },
      ],
    });
    const [group] = groupBlocked([held]);
    const shown = group.findingGroups.flatMap((rule) => rule.locations);
    expect(shown).toHaveLength(2);
  });
});

describe("a held-back item's settled findings", () => {
  it("names the publisher only where every occurrence behind the group is theirs", () => {
    const settled: FindingDecision = {
      fingerprint: "p",
      token: null,
      state: {
        state: "author-dismissed",
        reason: "intended",
        dismissedAt: "2026-08-16T00:00:00Z",
        publisher: "vanillagreencom/kendex",
      },
    };
    const open: FindingDecision = {
      fingerprint: "o",
      token: null,
      state: { state: "open", earlier: null },
    };
    const first: Finding = {
      rule: "safety-bypass",
      severity: "critical",
      location: "SKILL.md:4",
      message: "`--no-verify` skips the checks a commit runs",
      remediation: "leave the check in place",
    };
    const second: Finding = { ...first, location: "SKILL.md:9" };

    const both = groupFindingsByRule([first, second], [settled, settled]);
    expect(both).toHaveLength(1);
    expect(both[0].settledBy?.publisher).toBe("vanillagreencom/kendex");

    // One occurrence nobody ruled on and the reader still has something to
    // do here, so the group is not the publisher's to speak for.
    const mixed = groupFindingsByRule([first, second], [settled, open]);
    expect(mixed[0].settledBy).toBeNull();

    // And with no decisions at all — every other caller — nothing changes.
    expect(groupFindingsByRule([first, second], [])[0].settledBy).toBeNull();
  });
});
