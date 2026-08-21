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

  // Two tools locked to different revisions whose item bytes are identical
  // share a review hash, and the publisher can have changed their mind
  // between the two — or simply re-recorded the same call at a later date.
  // One entry can show one reason and one date, so merging prints a
  // judgement made for one tool over the other.
  it("keeps one publisher's two decisions apart, each with its own reason", () => {
    const reconsidered = decision({
      fingerprint: "p",
      state: {
        state: "author-dismissed",
        reason: "wrong-call",
        dismissedAt: "2026-08-19T00:00:00Z",
        publisher: "vanillagreencom/kendex",
      },
    });
    const groups = publisherGroups([
      row({ harness: "claude", decisions: [settledByPublisher] }),
      row({ harness: "codex", decisions: [reconsidered] }),
    ]);
    expect(groups).toHaveLength(2);
    expect(groups.map((group) => group.reason)).toEqual([
      "intended",
      "wrong-call",
    ]);
    expect(groups.map((group) => group.dismissedAt)).toEqual([
      "2026-08-16T00:00:00Z",
      "2026-08-19T00:00:00Z",
    ]);
    expect(
      groups.map((group) => group.items.map((item) => item.harness)),
    ).toEqual([["claude"], ["codex"]]);
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

  // A review hash seals the installed kind and the bytes, so two commands
  // with the same body from two catalogs share one. Merging them would
  // print the first catalog's name over content it never reviewed.
  it("keeps two catalogs' identical bytes apart, each under its own name", () => {
    const mine = row({
      kind: "command",
      name: "ship",
      decisions: [settledByPublisher],
    });
    const theirs = row({
      kind: "command",
      name: "deploy",
      decisions: [
        decision({
          fingerprint: "p",
          state: {
            state: "author-dismissed",
            reason: "intended",
            dismissedAt: "2026-08-16T00:00:00Z",
            publisher: "someone/else",
          },
        }),
      ],
    });
    const groups = publisherGroups([mine, theirs]);
    expect(groups).toHaveLength(2);
    expect(groups.map((group) => group.publisher)).toEqual([
      "vanillagreencom/kendex",
      "someone/else",
    ]);
    expect(groups.map((group) => group.items[0].name)).toEqual([
      "ship",
      "deploy",
    ]);
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
