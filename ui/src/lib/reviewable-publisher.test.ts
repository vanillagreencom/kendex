import { describe, expect, it } from "vitest";
import type { Finding, FindingDecision, ItemSafety } from "@/bindings";
import {
  authorSettledCount,
  publisherGroups,
  settledCount,
} from "./reviewable";

const FINDING: Finding = {
  rule: "dangerous-commands",
  severity: "medium",
  location: "SKILL.md:5",
  message: "makes files writable by every account",
  remediation: "narrow the command",
};

function decision(overrides: Partial<FindingDecision> = {}): FindingDecision {
  return {
    fingerprint: "aaaaaaaaaaaaaaaa",
    token: null,
    state: { state: "open", earlier: null },
    ...overrides,
  };
}

function row(overrides: Partial<ItemSafety> = {}): ItemSafety {
  return {
    kind: "skill",
    name: "mild",
    harness: "claude",
    scope: { scope: "global" },
    location: "",
    safety: { score: 92, deductions: [] },
    quality: null,
    findings: [FINDING],
    skipped: [],
    verdict: "warn",
    reasons: [],
    contentHash: "c",
    reviewHash: "hash-1",
    provenance: "owner/repo",
    override: { state: "absent" },
    decisions: [decision()],
    ...overrides,
  };
}

describe("publisherGroups", () => {
  const settledByPublisher = decision({
    fingerprint: "p",
    state: {
      state: "author-dismissed",
      reason: "intended",
      dismissedAt: "2026-08-16T00:00:00Z",
      publisher: "vanillagreencom/kendex",
    },
  });

  it("says one thing once for one shared tree read by three tools", () => {
    const tools = ["claude", "codex", "pi"] as const;
    const rows = tools.map((harness) =>
      row({ harness, decisions: [settledByPublisher] }),
    );
    const groups = publisherGroups(rows);
    expect(groups).toHaveLength(1);
    expect(groups[0].publisher).toBe("vanillagreencom/kendex");
    expect(groups[0].items.map((item) => item.harness)).toEqual([...tools]);
    // The count the footer sentence quotes is this list's length, not the
    // occurrence count, or the two disagree in one block.
    expect(authorSettledCount(rows)).toBe(3);
  });

  it("keeps different bytes apart", () => {
    const other = row({
      name: "other",
      reviewHash: "hash-2",
      decisions: [settledByPublisher],
    });
    expect(
      publisherGroups([row({ decisions: [settledByPublisher] }), other]),
    ).toHaveLength(2);
  });

  it("carries nothing the person decided themselves", () => {
    const mine = row({
      decisions: [
        decision({
          state: {
            state: "dismissed",
            reason: "wrong-call",
            dismissedAt: "2026-08-16T00:00:00Z",
          },
        }),
      ],
    });
    expect(publisherGroups([mine])).toEqual([]);
  });
});

describe("the two publisher counts in the footer", () => {
  const byPublisher = (fingerprint: string): FindingDecision =>
    decision({
      fingerprint,
      state: {
        state: "author-dismissed",
        reason: "intended",
        dismissedAt: "2026-08-16T00:00:00Z",
        publisher: "vanillagreencom/kendex",
      },
    });

  // The parenthetical qualifies the settled sentence, so it has to count
  // the same rows in the same unit. Counting deduplicated decisions across
  // settled, open and blocked rows let it claim more publisher decisions
  // than there were decisions at all.
  it("never claims more publisher decisions than the total it sits inside", () => {
    const settled = row({ decisions: [byPublisher("s")] });
    const open = row({
      name: "open",
      reviewHash: "hash-2",
      findings: [FINDING, { ...FINDING, location: "SKILL.md:9" }],
      decisions: [byPublisher("o"), decision({ fingerprint: "x" })],
    });
    const blocked = row({
      name: "blocked",
      reviewHash: "hash-3",
      verdict: "block",
      decisions: [byPublisher("b")],
    });

    const total = settledCount([settled]);
    const parenthetical = authorSettledCount([settled]);
    expect(parenthetical).toBeLessThanOrEqual(total);
    // The disclosure below it is its own count, over every scored row.
    expect(publisherGroups([settled, open, blocked])).toHaveLength(3);
  });
});
