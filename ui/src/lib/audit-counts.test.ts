import { describe, expect, it } from "vitest";
import type {
  AuditView,
  DriftRow,
  Finding,
  HarnessId,
  ItemSafety,
  RowExits,
} from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
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
  cause?: DriftRow["cause"],
): DriftRow {
  return {
    kind: "skill",
    name,
    harness,
    scope: root ? { scope: "project", root } : { scope: "global" },
    state,
    detail: "",
    cause,
  };
}

function view(
  rows: DriftRow[],
  root?: string,
  safety: ItemSafety[] = [],
  exits: RowExits[] = [],
): AuditView {
  return {
    scope: root ? { scope: "project", root } : { scope: "global" },
    drift: rows,
    plan: [],
    notes: [],
    warnings: [],
    safety,
    adoptable: ADOPTABLE,
    exits,
    heldBack: [],
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

describe("a declaration whose files are already there", () => {
  // Apply cannot move these rows — only a person picking which way they go
  // — so counting them beside the writes it is about to make tells Home and
  // the footer to promise a button that will not touch them.
  it("is a decision waiting, not a change ready to apply", () => {
    const counts = auditCounts([
      view(
        [
          drift("deploy", "claude", "conflict", undefined, "unmanaged-content"),
          drift("lint", "claude", "stale"),
        ],
        undefined,
        [],
        [
          {
            key: "skill:deploy:claude",
            blocking: true,
            files: true,
            keep: true,
            enter: true,
            replace: true,
          },
        ],
      ),
    ]);

    expect(counts.changes).toBe(1);
    expect(counts.inTheWay).toBe(1);
    expect(decisionsPendingCount(counts)).toBe(1);
    expect(needsReviewCount(counts)).toBe(2);
  });
});
