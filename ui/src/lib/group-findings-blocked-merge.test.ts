// Which held-back rows the panel collapses into one entry, and which it
// must not: rows whose findings match but whose decisions do not are two
// things to tell the reader.
import { describe, expect, it } from "vitest";
import type { Finding, FindingDecision, ItemSafety } from "@/bindings";
import { groupBlocked } from "./group-findings-blocked";

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

  // Attribution is the disclosure that justifies honouring somebody else's
  // review at all, so it can never come from whichever row sorted first.
  it("keeps rows apart when the same findings were decided differently", () => {
    const settled = (state: FindingDecision["state"]): FindingDecision => ({
      fingerprint: "a",
      token: null,
      state,
    });
    const byPublisher = row({
      harness: "codex",
      decisions: [
        settled({
          state: "author-dismissed",
          reason: "intended",
          dismissedAt: "2026-08-16T00:00:00Z",
          publisher: "vanillagreencom/kendex",
        }),
      ],
    });
    const byMe = row({
      harness: "pi",
      decisions: [
        settled({
          state: "dismissed",
          reason: "wrong-call",
          dismissedAt: "2026-08-17T00:00:00Z",
        }),
      ],
    });
    const untouched = row({
      harness: "claude",
      decisions: [settled({ state: "open", earlier: null })],
    });

    const groups = groupBlocked([byPublisher, byMe, untouched]);
    expect(groups).toHaveLength(3);
    expect(groups[0].findingGroups[0].settledBy?.publisher).toBe(
      "vanillagreencom/kendex",
    );
    expect(groups[0].rows.map((r) => r.harness)).toEqual(["codex"]);
    expect(groups[1].findingGroups[0].settledBy).toBeNull();
    expect(groups[2].findingGroups[0].settledBy).toBeNull();
  });

  // And an agreement still merges: one publisher's record read on three
  // tools is one thing to say, with every tool named under it.
  it("still merges rows the same publisher settled the same way", () => {
    const byPublisher = (harness: ItemSafety["harness"]) =>
      row({
        harness,
        decisions: [
          {
            fingerprint: "a",
            token: null,
            state: {
              state: "author-dismissed",
              reason: "intended",
              dismissedAt: "2026-08-16T00:00:00Z",
              publisher: "vanillagreencom/kendex",
            },
          },
        ],
      });
    const groups = groupBlocked([
      byPublisher("codex"),
      byPublisher("pi"),
      byPublisher("claude"),
    ]);
    expect(groups).toHaveLength(1);
    expect(groups[0].rows.map((r) => r.harness)).toEqual([
      "codex",
      "pi",
      "claude",
    ]);
    expect(groups[0].findingGroups[0].settledBy?.publisher).toBe(
      "vanillagreencom/kendex",
    );
  });

  it("keeps different names apart even with identical findings", () => {
    const a = row({ name: "visual-qa" });
    const b = row({ name: "other-skill" });
    expect(groupBlocked([a, b])).toHaveLength(2);
  });
});
