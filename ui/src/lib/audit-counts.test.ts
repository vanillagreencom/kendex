import { describe, expect, it } from "vitest";
import type {
  AuditView,
  DriftRow,
  Finding,
  HarnessId,
  ItemSafety,
} from "@/bindings";
import {
  auditCounts,
  decisionsPendingCount,
  needsReviewCount,
} from "./audit-counts";

function drift(
  name: string,
  harness: HarnessId,
  state: DriftRow["state"],
  root?: string,
): DriftRow {
  return {
    kind: "skill",
    name,
    harness,
    scope: root ? { scope: "project", root } : { scope: "global" },
    state,
    subject: "package",
    detail: "",
  };
}

function view(
  rows: DriftRow[],
  root?: string,
  safety: ItemSafety[] = [],
  heldBack: ItemSafety[] = [],
): AuditView {
  return {
    scope: root ? { scope: "project", root } : { scope: "global" },
    drift: rows,
    plan: [],
    notes: [],
    warnings: [],
    safety,
    heldBack,
    queued: [],
  };
}

const FINDING: Finding = {
  rule: "dangerous-commands",
  severity: "medium",
  location: "SKILL.md:5",
  message: "makes files writable by every account",
  remediation: "narrow the command",
};

/** One installed item carrying one finding, decided or not. */
function safety(
  name: string,
  harness: HarnessId,
  decided: boolean,
  hash = "hash-1",
  overrides: Partial<ItemSafety> = {},
): ItemSafety {
  return {
    kind: "skill",
    name,
    harness,
    scope: { scope: "global" },
    location: "",
    safety: { score: 92, deductions: [] },
    quality: null,
    findings: [FINDING],
    skipped: [],
    verdict: "warn",
    reasons: [],
    contentHash: "c",
    reviewHash: hash,
    provenance: null,
    override: { state: "absent" },
    decisions: [
      {
        fingerprint: "aaaaaaaaaaaaaaaa",
        token: `skill:${name}:${harness}#aaaaaaaaaaaaaaaa@${hash}`,
        state: decided
          ? {
              state: "dismissed",
              reason: "wrong-call",
              dismissedAt: "2026-08-16T00:00:00Z",
            }
          : { state: "open", earlier: null },
      },
    ],
    ...overrides,
  };
}

describe("auditCounts", () => {
  it("counts one item installed for five tools once", () => {
    const tools: HarnessId[] = ["claude", "codex", "opencode", "cursor", "pi"];
    const rows = tools.map((h) => drift("agent-browser", h, "unmanaged"));

    expect(auditCounts([view(rows)])).toMatchObject({
      unmanaged: 1,
      changes: 0,
    });
  });

  it("keeps the same name in two projects apart", () => {
    const personal = view([drift("github", "claude", "unmanaged")]);
    const project = view([drift("github", "claude", "unmanaged", "/p")], "/p");

    expect(auditCounts([personal, project]).unmanaged).toBe(2);
  });

  it("separates queued work from what was never adopted", () => {
    const rows = [
      drift("a", "claude", "stale"),
      drift("b", "claude", "missing"),
      drift("c", "claude", "unmanaged"),
    ];

    expect(auditCounts([view(rows)])).toMatchObject({
      changes: 2,
      unmanaged: 1,
    });
  });

  // A conflict has no ops behind it, so no button applies it — counting it
  // among the changes tells the person work is queued that nothing will do.
  it("counts a conflict apart from the work a button can apply", () => {
    const rows = [
      drift("a", "claude", "stale"),
      drift("forked", "claude", "conflict"),
    ];
    const counts = auditCounts([view(rows)]);
    expect(counts.changes).toBe(1);
    expect(counts.conflicts).toBe(1);
    // Still something to go and settle, so it stays in the review badge —
    // but it is not a decision anyone is waiting on here.
    expect(needsReviewCount(counts)).toBe(2);
    expect(decisionsPendingCount(counts)).toBe(0);
  });

  // The gate emits a conflict for what it refused, and the refusal is
  // already counted as held back. Counting it twice makes the badge say two
  // where a person sees one thing to settle.
  it("counts a safety refusal once, where its decision lives", () => {
    const refused = safety("hostile", "claude", false, "h1", {
      verdict: "block",
    });
    const counts = auditCounts([
      view([drift("hostile", "claude", "conflict")], undefined, [], [refused]),
    ]);
    expect(counts.blocked).toBe(1);
    expect(counts.conflicts).toBe(0);
    expect(counts.changes).toBe(0);
    expect(needsReviewCount(counts)).toBe(1);
  });

  it("leaves un-adopted items out of what needs reviewing", () => {
    const rows = [
      drift("a", "claude", "stale"),
      drift("c", "claude", "unmanaged"),
    ];

    expect(needsReviewCount(auditCounts([view(rows)]))).toBe(1);
  });

  it("counts an open finding once per piece of evidence and a dismissed one never", () => {
    const rows = [
      safety("mild", "claude", false),
      safety("mild", "codex", false),
      safety("other", "claude", false, "hash-2"),
      safety("done", "claude", true, "hash-3"),
    ];
    const counts = auditCounts([view([], undefined, rows)]);
    expect(counts.open).toBe(2);
    expect(counts.blocked).toBe(0);
    expect(needsReviewCount(counts)).toBe(2);
    expect(decisionsPendingCount(counts)).toBe(2);
  });

  it("stops asking once every finding is decided", () => {
    const rows = [safety("done", "claude", true)];
    expect(needsReviewCount(auditCounts([view([], undefined, rows)]))).toBe(0);
  });

  it("counts a held-back item once, and an accepted one not at all", () => {
    const rows = [
      safety("hostile", "claude", false, "h1", { verdict: "block" }),
      safety("hostile", "codex", false, "h1", { verdict: "block" }),
      safety("accepted", "claude", false, "h2", {
        verdict: "block",
        override: { state: "active" },
        decisions: [
          {
            fingerprint: "aaaaaaaaaaaaaaaa",
            token: "skill:accepted:claude#aaaaaaaaaaaaaaaa@h2",
            state: { state: "accepted", grantedAt: "2026-08-16T00:00:00Z" },
          },
        ],
      }),
    ];
    const counts = auditCounts([view([], undefined, rows)]);
    expect(counts.blocked).toBe(1);
    expect(counts.open).toBe(0);
    expect(decisionsPendingCount(counts)).toBe(1);
  });
});
