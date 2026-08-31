import { describe, expect, it } from "vitest";
import type {
  AuditView,
  Finding,
  HarnessId,
  ItemSafety,
  Severity,
} from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { findingKey, installedSafety } from "./installed-safety";

const GLOBAL = { scope: "global" } as const;

function finding(rule: string, severity: Severity, line = 1): Finding {
  return {
    rule,
    severity,
    location: `${rule}.md`,
    line,
    message: `${rule} fired`,
    remediation: "",
  };
}

function row(
  harness: HarnessId,
  score: number,
  findings: Finding[],
): ItemSafety {
  return {
    kind: "skill",
    name: "github",
    harness,
    scope: GLOBAL,
    location: "github",
    findings,
    skipped: [],
    safety: { score, deductions: [] },
    quality: null,
    ruleset: 1,
  };
}

function view(safety: ItemSafety[]): AuditView {
  return {
    scope: GLOBAL,
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety,
    adoptable: ADOPTABLE,
    exits: [],
  };
}

describe("installedSafety", () => {
  it("takes the lowest score, with the findings that earned it", () => {
    const rows = view([
      row("claude", 90, [finding("clean", "low")]),
      row("codex", 40, [finding("curl-pipe-sh", "critical")]),
    ]);

    const result = installedSafety([rows], "skill", "github", [GLOBAL]);

    expect(result?.safety.score).toBe(40);
    expect(result?.findings.map((f) => f.rule)).toEqual(["curl-pipe-sh"]);
  });

  // Rows that tie on score leave the first one standing, so the merge
  // never churns between two equal readings.
  it("leaves the standing row alone when nothing separates them", () => {
    const first = row("claude", 75, [finding("wide-glob", "high")]);
    const second = row("codex", 75, [finding("env-read", "high")]);

    const result = installedSafety([view([first, second])], "skill", "github", [
      GLOBAL,
    ]);

    expect(result?.findings.map((f) => f.rule)).toEqual(["wide-glob"]);
  });

  it("has no reading for a package no row mentions", () => {
    const result = installedSafety([view([])], "skill", "github", [GLOBAL]);

    expect(result).toBeNull();
  });
});

describe("a finding's identity", () => {
  // One rule fires at many lines of one file. While the line lived inside
  // `location` the fold could tell them apart for free; taking it out
  // without putting it in the key showed one problem where there are two.
  it("keeps two findings that differ only by line", () => {
    const first = finding("dangerous-commands", "high", 848);
    const second = finding("dangerous-commands", "high", 950);
    expect(findingKey(first)).not.toBe(findingKey(second));

    const rows = view([row("claude", 60, [first, second])]);
    const reading = installedSafety([rows], "skill", "github", [GLOBAL]);
    expect(reading?.findings).toHaveLength(2);
    expect(reading?.findings.map((f) => f.line)).toEqual([848, 950]);
  });

  it("still folds a finding that is the same in every respect", () => {
    const twice = [
      finding("dangerous-commands", "high", 848),
      finding("dangerous-commands", "high", 848),
    ];
    const rows = view([row("claude", 60, twice)]);
    const reading = installedSafety([rows], "skill", "github", [GLOBAL]);
    expect(reading?.findings).toHaveLength(1);
  });
});
