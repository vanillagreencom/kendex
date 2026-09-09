import { describe, expect, it } from "vitest";
import type {
  AuditView,
  Finding,
  HarnessId,
  ItemSafety,
  Severity,
} from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import {
  findingKey,
  installedSafety,
  safetyStanding,
} from "./installed-safety";

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
    source: null,
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

  it("selects severity ties and preserves the first equally ranked reading", () => {
    const gentler = row("claude", 75, [
      finding("wide-glob", "high"),
      finding("env-read", "medium"),
    ]);
    const harsher = row("codex", 75, [finding("curl-pipe-sh", "critical")]);
    const rows = [
      {
        name: "harsher last",
        safety: [gentler, harsher],
        expected: ["curl-pipe-sh"],
      },
      {
        name: "harsher first",
        safety: [harsher, gentler],
        expected: ["curl-pipe-sh"],
      },
      {
        name: "score floor",
        safety: [
          row("claude", 0, [finding("wide-glob", "high")]),
          row("codex", 0, [finding("curl-pipe-sh", "critical")]),
        ],
        expected: ["curl-pipe-sh"],
      },
      {
        name: "equal score and severity",
        safety: [
          row("claude", 75, [finding("wide-glob", "high")]),
          row("codex", 75, [finding("env-read", "high")]),
        ],
        expected: ["wide-glob"],
      },
      { name: "no package reading", safety: [], expected: null },
    ];
    expect(
      rows.length,
      "installed safety selection table is empty",
    ).toBeGreaterThan(0);
    for (const entry of rows) {
      const result = installedSafety([view(entry.safety)], "skill", "github", [
        GLOBAL,
      ]);
      expect(
        result === null ? null : result.findings.map((f) => f.rule),
        entry.name,
      ).toEqual(entry.expected);
    }
  });
});

describe("a finding's identity", () => {
  // One rule fires at many lines of one file. A key without the line
  // shows one problem where there are two.
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

const VG = { scope: "project", root: "/work/vg" } as const;

const at = (scope: AuditView["scope"], safety: ItemSafety[], error?: string) =>
  ({
    ...view(safety),
    scope,
    ...(error ? { error: { message: error } } : {}),
  }) as AuditView;

const scoredAt = (scope: AuditView["scope"]) =>
  ({ ...row("claude", 58, [finding("risky", "high")]), scope }) as ItemSafety;

// Every shipped state a score can be in, decided in one place. The words a
// score shows and the place they are true of come from this one answer, so
// a surface cannot pair a current number with another place's failure, or
// point a reader at a place the words were never about.
describe("safetyStanding", () => {
  const cases = [
    {
      name: "nothing has answered",
      views: [],
      auditFailure: null,
      answered: false,
      state: "waiting",
      at: null,
    },
    {
      name: "the audit answered and said nothing about this package",
      views: [at(GLOBAL, [])],
      auditFailure: null,
      answered: true,
      state: "unscored",
      at: null,
    },
    {
      name: "a reading the check took",
      views: [at(GLOBAL, [scoredAt(GLOBAL)])],
      auditFailure: null,
      answered: true,
      state: "read",
      at: GLOBAL,
    },
    {
      name: "a reading whose own place then failed",
      views: [at(GLOBAL, [scoredAt(GLOBAL)], "could not read personal")],
      auditFailure: null,
      answered: true,
      state: "stale",
      at: GLOBAL,
    },
    {
      // The number is current: the place that failed says its piece on its
      // own row rather than dating a reading it is not about.
      name: "another place failed beside a place that scored",
      views: [at(GLOBAL, [scoredAt(GLOBAL)]), at(VG, [], "could not read vg")],
      auditFailure: null,
      answered: true,
      state: "read",
      at: GLOBAL,
    },
    {
      name: "no reading, because that place could not be read",
      views: [at(VG, [], "could not read vg")],
      auditFailure: null,
      answered: true,
      state: "failed",
      at: VG,
    },
    {
      name: "the audit failed as a whole with nothing kept",
      views: [],
      auditFailure: "the audit crashed",
      answered: true,
      state: "unavailable",
      at: null,
    },
    {
      // A failed read keeps the views it had, so a reading from before it
      // is still there — and it is that reading the failure now dates.
      name: "the audit failed as a whole over a kept reading",
      views: [at(GLOBAL, [scoredAt(GLOBAL)])],
      auditFailure: "the audit crashed",
      answered: true,
      state: "stale",
      at: GLOBAL,
    },
    {
      // The regression: a kept view that failed on its own before the audit
      // failed as a whole. The whole audit's failure names no place, so
      // nothing may still offer that place as where it can be read.
      name: "the audit failed as a whole after a place had failed",
      views: [at(VG, [], "could not read vg")],
      auditFailure: "the audit crashed",
      answered: true,
      state: "unavailable",
      at: null,
    },
  ] satisfies {
    name: string;
    views: AuditView[];
    auditFailure: string | null;
    answered: boolean;
    state: string;
    at: AuditView["scope"] | null;
  }[];

  it("names the state and the place it is true of, together", () => {
    expect(cases).toHaveLength(9);
    for (const one of cases) {
      const standing = safetyStanding(
        one.views,
        one.auditFailure,
        one.answered,
        "skill",
        "github",
        [GLOBAL, VG],
      );
      expect({ state: standing.state, at: standing.at }, one.name).toEqual({
        state: one.state,
        at: one.at,
      });
      // Where the words name a place, that place is one the caller asked
      // about — never a third the reader was never shown.
      if (standing.at !== null)
        expect([GLOBAL, VG], one.name).toContainEqual(standing.at);
    }
  });
});
