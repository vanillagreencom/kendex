import { describe, expect, it } from "vitest";
import type { Finding, ItemSafety } from "@/bindings";
import {
  concernDetails,
  groupByConcern,
  groupFindings as groupOccurrences,
} from "./group-findings";
import { openOccurrences } from "./reviewable";

const FINDING: Finding = {
  rule: "dangerous-commands",
  severity: "high",
  location: "settings.json:17",
  message: "`mkfs` formats a filesystem",
  remediation: "narrow the command to the exact path it needs",
};

/** A row whose findings each carry an open decision beside them, the way
 *  the backend issues them. */
function row(overrides: Partial<ItemSafety>): ItemSafety {
  const findings = overrides.findings ?? [];
  return {
    kind: "hook",
    name: "a-hook",
    harness: "claude",
    scope: { scope: "global" },
    safety: { score: 85, deductions: [] },
    quality: null,
    findings: [],
    skipped: [],
    verdict: "warn",
    reasons: [],
    contentHash: "hash",
    reviewHash: "review-hash",
    location: "",
    provenance: null,
    decisions: findings.map((finding, index) => ({
      fingerprint: `${finding.rule}:${index}`,
      token: `hook:${overrides.name ?? "a-hook"}:claude#${index}@review-hash`,
      state: { state: "open", earlier: null },
    })),
    override: { state: "absent" },
    ...overrides,
  };
}

const groupFindings = (rows: ItemSafety[]) =>
  groupOccurrences(openOccurrences(rows));

describe("groupByConcern", () => {
  it("collapses one rule firing in several places into a single concern", () => {
    const groups = groupFindings([
      row({ name: "a", findings: [FINDING] }),
      row({ name: "b", findings: [{ ...FINDING, location: "other.json:3" }] }),
      row({ name: "c", findings: [{ ...FINDING, location: "third.json:9" }] }),
    ]);
    expect(groups).toHaveLength(1);
    expect(groups[0].locations).toHaveLength(3);
    const concerns = groupByConcern(groups);
    expect(concerns).toHaveLength(1);
    expect(concerns[0].findings).toHaveLength(1);
    expect(concerns[0].items.map((i) => i.name)).toEqual(["a", "b", "c"]);
  });

  it("counts an item once when the same rule hits it from two findings", () => {
    const concerns = groupByConcern(
      groupFindings([
        row({
          name: "a",
          findings: [FINDING, { ...FINDING, location: "other.json:3" }],
        }),
      ]),
    );
    expect(concerns[0].items).toHaveLength(1);
  });

  it("keeps different rules apart and leads with the most serious", () => {
    const concerns = groupByConcern(
      groupFindings([
        row({ name: "a", findings: [{ ...FINDING, severity: "low" }] }),
        row({
          name: "b",
          findings: [{ ...FINDING, rule: "rce", severity: "critical" }],
        }),
      ]),
    );
    expect(concerns.map((c) => c.rule)).toEqual(["rce", "dangerous-commands"]);
  });

  it("takes a concern's severity from its most serious finding", () => {
    const concerns = groupByConcern(
      groupFindings([
        row({ name: "a", findings: [{ ...FINDING, severity: "low" }] }),
        row({
          name: "b",
          findings: [
            { ...FINDING, severity: "critical", location: "other.json:3" },
          ],
        }),
      ]),
    );
    expect(concerns[0].severity).toBe("critical");
  });
});

describe("concernDetails", () => {
  it("says one repeated message once and lists every place it fired", () => {
    const concern = groupByConcern(
      groupFindings([
        row({ name: "a", findings: [FINDING] }),
        row({
          name: "b",
          findings: [{ ...FINDING, location: "other.json:3" }],
        }),
      ]),
    )[0];
    const details = concernDetails(concern);
    expect(details).toHaveLength(1);
    expect(details[0].locations).toEqual(["settings.json:17", "other.json:3"]);
  });

  it("keeps genuinely different messages under the same rule apart", () => {
    const concern = groupByConcern(
      groupFindings([
        row({ name: "a", findings: [FINDING] }),
        row({
          name: "b",
          findings: [{ ...FINDING, message: "`dd` overwrites a disk" }],
        }),
      ]),
    )[0];
    expect(concernDetails(concern)).toHaveLength(2);
  });
});
