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
    targets: [{ harness, location: "github" }],
    scope: GLOBAL,
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

  // The score is 100 less what the findings cost, so one critical costs
  // what several lighter hits do and every ruined reading floors at 0. On a
  // tie the harsher row has to win, or the order the backend returned rows
  // in decides which findings a reader ever sees.
  it("breaks a tied score by the worse severity, whatever the row order", () => {
    const gentler = row("claude", 75, [
      finding("wide-glob", "high"),
      finding("env-read", "medium"),
    ]);
    const harsher = row("codex", 75, [finding("curl-pipe-sh", "critical")]);

    const harsherLast = installedSafety(
      [view([gentler, harsher])],
      "skill",
      "github",
      [GLOBAL],
    );
    const harsherFirst = installedSafety(
      [view([harsher, gentler])],
      "skill",
      "github",
      [GLOBAL],
    );

    expect(harsherLast?.findings.map((f) => f.rule)).toEqual(["curl-pipe-sh"]);
    expect(harsherFirst?.findings.map((f) => f.rule)).toEqual(["curl-pipe-sh"]);
  });

  it("keeps both readings apart at the floor, where every score is 0", () => {
    const one = row("claude", 0, [finding("wide-glob", "high")]);
    const many = row("codex", 0, [finding("curl-pipe-sh", "critical")]);

    const result = installedSafety([view([one, many])], "skill", "github", [
      GLOBAL,
    ]);

    expect(result?.findings.map((f) => f.rule)).toEqual(["curl-pipe-sh"]);
  });

  // The control: rows that match on score and on severity leave the first
  // one standing, so the merge never churns between two equal readings.
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
