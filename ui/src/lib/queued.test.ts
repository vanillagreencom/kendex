import { describe, expect, it } from "vitest";
import type { AuditView, ItemSafety } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { queuedDecisions } from "./queued";

function row(name: string, hash: string, dismissed = false): ItemSafety {
  return {
    kind: "skill",
    name,
    harness: "claude",
    scope: { scope: "global" },
    location: "",
    safety: { score: 92, deductions: [] },
    quality: null,
    findings: [
      {
        rule: "dangerous-commands",
        severity: "medium",
        location: "SKILL.md:5",
        message: "m",
        remediation: "r",
      },
    ],
    skipped: [],
    verdict: "warn",
    reasons: [],
    contentHash: "c",
    reviewHash: hash,
    provenance: null,
    override: { state: "absent" },
    decisions: [
      {
        fingerprint: "f",
        token: `skill:${name}:claude#f@${hash}`,
        state: dismissed
          ? {
              state: "dismissed",
              reason: "intended",
              dismissedAt: "2026-08-16T00:00:00Z",
            }
          : { state: "open", earlier: null },
      },
    ],
  };
}

function view(safety: ItemSafety[], queued: ItemSafety[]): AuditView {
  return {
    scope: { scope: "global" },
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety,
    adoptable: ADOPTABLE,
    exits: [],
    heldBack: [],
    queued,
  };
}

describe("queuedDecisions", () => {
  it("counts new or changing content, not what is already installed unchanged", () => {
    const installed = row("same", "hash-1");
    const queued = [
      row("same", "hash-1"),
      row("fresh", "hash-2"),
      row("changed", "hash-3"),
    ];
    expect(
      queuedDecisions(view([installed, row("changed", "hash-old")], queued)),
    ).toBe(2);
  });

  it("leaves out findings already decided", () => {
    expect(queuedDecisions(view([], [row("fresh", "hash-2", true)]))).toBe(0);
  });
});
