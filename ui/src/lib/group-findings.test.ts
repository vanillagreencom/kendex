import { describe, expect, it } from "vitest";
import type { Finding, ItemSafety } from "@/bindings";
import {
  concernDetails,
  groupByConcern,
  groupFindings as groupOccurrences,
  partitionSafety,
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

describe("partitionSafety", () => {
  it("splits rows into held-back, open, settled and clean buckets", () => {
    const blockedNoOverride = row({ verdict: "block", name: "held" });
    const blockedOverridden = row({
      verdict: "block",
      name: "accepted",
      override: { state: "active" },
    });
    const warnRow = row({
      verdict: "warn",
      name: "warned",
      findings: [FINDING],
    });
    const dismissedRow = row({
      verdict: "warn",
      name: "settled",
      findings: [FINDING],
    });
    dismissedRow.decisions[0].state = {
      state: "dismissed",
      reason: "intended",
      dismissedAt: "2026-08-16T00:00:00Z",
    };
    const cleanRow = row({ verdict: "clean", name: "clean" });

    const groups = partitionSafety([
      warnRow,
      dismissedRow,
      cleanRow,
      blockedOverridden,
      blockedNoOverride,
    ]);

    expect(groups.open).toEqual([warnRow]);
    expect(groups.settled).toEqual([dismissedRow]);
    expect(groups.clean).toEqual([cleanRow]);
    expect(groups.blocked.map((r) => r.name)).toEqual(["held", "accepted"]);
  });

  it("a row whose every finding is dismissed no longer asks for anything", () => {
    const settled = row({
      verdict: "warn",
      name: "settled",
      findings: [FINDING],
    });
    settled.decisions[0].state = {
      state: "dismissed",
      reason: "wrong-call",
      dismissedAt: "2026-08-16T00:00:00Z",
    };
    expect(partitionSafety([settled]).open).toEqual([]);
    expect(groupFindings([settled])).toEqual([]);
  });
});

describe("groupFindings", () => {
  it("dedupes an identical finding across many rows into one group", () => {
    const rows = ["a", "b", "c"].map((name) =>
      row({ name, findings: [FINDING] }),
    );
    const groups = groupFindings(rows);
    expect(groups).toHaveLength(1);
    expect(groups[0].items.map((i) => i.name)).toEqual(["a", "b", "c"]);
    expect(groups[0].message).toBe(FINDING.message);
  });

  it("keeps findings separate when rule, location, or message differ", () => {
    const rows = [
      row({ name: "a", findings: [FINDING] }),
      row({ name: "b", findings: [{ ...FINDING, location: "other:1" }] }),
      row({ name: "c", findings: [{ ...FINDING, message: "different" }] }),
    ];
    expect(groupFindings(rows)).toHaveLength(3);
  });

  it("gives a finding affecting exactly one row a group of one", () => {
    const groups = groupFindings([row({ name: "solo", findings: [FINDING] })]);
    expect(groups).toHaveLength(1);
    expect(groups[0].items).toHaveLength(1);
    expect(groups[0].items[0].name).toBe("solo");
  });
});

describe("groupByConcern", () => {
  it("collapses one rule firing in several places into a single concern", () => {
    const groups = groupFindings([
      row({ name: "a", findings: [FINDING] }),
      row({ name: "b", findings: [{ ...FINDING, location: "other.json:3" }] }),
      row({ name: "c", findings: [{ ...FINDING, location: "third.json:9" }] }),
    ]);
    expect(groups).toHaveLength(3);
    const concerns = groupByConcern(groups);
    expect(concerns).toHaveLength(1);
    expect(concerns[0].findings).toHaveLength(3);
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

describe("partitionSafety and the publisher's own decisions", () => {
  it("keeps a row whose findings the publisher settled out of the clean bucket", () => {
    // Every finding settled means nothing counts, so the verdict is clean —
    // but the findings are still there to read, and a row in `clean` is
    // rendered as "nothing to report".
    const settled = row({
      verdict: "clean",
      name: "growth-guards",
      findings: [FINDING],
    });
    settled.decisions[0].state = {
      state: "author-dismissed",
      reason: "intended",
      dismissedAt: "2026-08-16T00:00:00Z",
      publisher: "vanillagreencom/kendex",
    };
    const nothingFound = row({ verdict: "clean", name: "quiet" });

    const groups = partitionSafety([settled, nothingFound]);
    expect(groups.settled).toEqual([settled]);
    expect(groups.clean).toEqual([nothingFound]);
    expect(groups.open).toEqual([]);
  });
});
