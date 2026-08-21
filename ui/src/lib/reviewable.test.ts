import { describe, expect, it } from "vitest";
import type { Finding, FindingDecision, ItemSafety } from "@/bindings";
import {
  authorOccurrences,
  authorSettledCount,
  evidenceGroups,
  openOccurrences,
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
    token: "skill:mild:claude#aaaaaaaaaaaaaaaa@hash-1",
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

describe("openOccurrences", () => {
  it("offers only undecided findings on items the gate is not holding back", () => {
    const dismissed = row({
      name: "settled",
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
    const blocked = row({ name: "hostile", verdict: "block" });
    const open = openOccurrences([row(), dismissed, blocked]);
    expect(open.map((o) => o.row.name)).toEqual(["mild"]);
    expect(settledCount([row(), dismissed, blocked])).toBe(1);
  });

  it("treats a decision the content outran as open again, not as settled", () => {
    const mixed = row({
      findings: [
        FINDING,
        { ...FINDING, location: "SKILL.md:9" },
        { ...FINDING, location: "SKILL.md:12" },
      ],
      decisions: [
        decision({
          fingerprint: "a",
          state: {
            state: "dismissed",
            reason: "intended",
            dismissedAt: "2026-08-16T00:00:00Z",
          },
        }),
        decision({
          fingerprint: "b",
          state: {
            state: "open",
            earlier: "the content changed since it was reviewed",
          },
        }),
        decision({
          fingerprint: "c",
          state: { state: "accepted", grantedAt: "2026-08-16T00:00:00Z" },
        }),
      ],
    });
    const open = openOccurrences([mixed]);
    expect(open).toHaveLength(1);
    expect(open[0].decision.fingerprint).toBe("b");
    expect(settledCount([mixed])).toBe(2);
    expect(evidenceGroups(open)[0].earlier).toBe(
      "the content changed since it was reviewed",
    );
  });

  it("refuses a row whose decisions do not line up with its findings", () => {
    expect(() => openOccurrences([row({ decisions: [] })])).toThrow(
      /no decision beside it/,
    );
  });
});

describe("evidenceGroups", () => {
  it("merges the same bytes seen through several tools into one decision", () => {
    const codex = row({
      harness: "codex",
      decisions: [
        decision({ token: "skill:mild:codex#aaaaaaaaaaaaaaaa@hash-1" }),
      ],
    });
    const pi = row({
      harness: "pi",
      decisions: [decision({ token: "skill:mild:pi#aaaaaaaaaaaaaaaa@hash-1" })],
    });
    const groups = evidenceGroups(openOccurrences([codex, pi]));
    expect(groups).toHaveLength(1);
    expect(groups[0].tokens).toEqual([
      "skill:mild:codex#aaaaaaaaaaaaaaaa@hash-1",
      "skill:mild:pi#aaaaaaaaaaaaaaaa@hash-1",
    ]);
    expect(groups[0].items.map((i) => i.harness)).toEqual(["codex", "pi"]);
  });

  // One decision covers every place the evidence was found, and a person
  // about to make it is owed the whole of what they are deciding about —
  // the same disclosure the publisher's list owes about somebody else's
  // decision.
  it("names every place one decision would cover", () => {
    const at = (location: string): Finding => ({ ...FINDING, location });
    const twice = row({
      findings: [at("SKILL.md:5"), at("SKILL.md:41")],
      decisions: [decision(), decision()],
    });
    const groups = evidenceGroups(openOccurrences([twice]));
    expect(groups).toHaveLength(1);
    expect(groups[0].locations).toEqual(["SKILL.md:5", "SKILL.md:41"]);
  });

  it("keeps different content apart however alike the sentence reads", () => {
    const one = row({ name: "plugin-a", reviewHash: "hash-a" });
    const two = row({
      name: "plugin-b",
      reviewHash: "hash-b",
      decisions: [
        decision({ token: "skill:plugin-b:claude#aaaaaaaaaaaaaaaa@hash-b" }),
      ],
    });
    expect(evidenceGroups(openOccurrences([one, two]))).toHaveLength(2);
  });

  // A review hash seals the kind and the bytes, so two commands with the
  // same body share one. One row for both would carry one name over a
  // button that settles the other as well.
  it("keeps two items' identical bytes apart, each under its own name", () => {
    const ship = row({ kind: "command", name: "ship" });
    const deploy = row({
      kind: "command",
      name: "deploy",
      decisions: [
        decision({ token: "command:deploy:claude#aaaaaaaaaaaaaaaa@hash-1" }),
      ],
    });
    const groups = evidenceGroups(openOccurrences([ship, deploy]));
    expect(groups.map((group) => group.items[0].name)).toEqual([
      "ship",
      "deploy",
    ]);
  });

  it("only offers trusting a source when every installation can name one", () => {
    const named = row();
    const nameless = row({ name: "loose", provenance: null });
    const [a, b] = evidenceGroups(
      openOccurrences([
        named,
        {
          ...nameless,
          reviewHash: "hash-2",
          decisions: [decision({ token: "x#y@hash-2" })],
        },
      ]),
    );
    expect(a.canTrustSource).toBe(true);
    expect(b.canTrustSource).toBe(false);
  });

  it("keeps a finding that has no token to decide with, so it is still counted", () => {
    const unreadable = row({
      reviewHash: null,
      decisions: [decision({ token: null })],
    });
    const groups = evidenceGroups(openOccurrences([unreadable]));
    expect(groups).toHaveLength(1);
    expect(groups[0].tokens).toEqual([]);
  });
});

describe("authorOccurrences", () => {
  const settledByPublisher = decision({
    fingerprint: "p",
    state: {
      state: "author-dismissed",
      reason: "intended",
      dismissedAt: "2026-08-16T00:00:00Z",
      publisher: "vanillagreencom/kendex",
    },
  });
  const settledByMe = decision({
    fingerprint: "m",
    state: {
      state: "dismissed",
      reason: "wrong-call",
      dismissedAt: "2026-08-16T00:00:00Z",
    },
  });

  it("counts what the publisher settled and not what the person did", () => {
    const mixed = row({
      findings: [FINDING, { ...FINDING, location: "SKILL.md:9" }],
      decisions: [settledByPublisher, settledByMe],
    });
    expect(
      authorOccurrences([mixed]).map((o) => o.decision.fingerprint),
    ).toEqual(["p"]);
    expect(authorSettledCount([mixed])).toBe(1);
    // Always a subset: both are decided, only one of them by the publisher.
    expect(settledCount([mixed])).toBe(2);
  });

  it("finds them on a row that still has open findings beside them", () => {
    const beside = row({
      findings: [FINDING, { ...FINDING, location: "SKILL.md:9" }],
      decisions: [settledByPublisher, decision({ fingerprint: "o" })],
    });
    expect(authorSettledCount([beside])).toBe(1);
    expect(openOccurrences([beside])).toHaveLength(1);
  });
});
