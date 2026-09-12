import { describe, expect, it } from "vitest";
import type { ProvenanceRow } from "@/bindings";
import { seededSummaryIndex } from "./package-identity";

const row = (overrides: Partial<ProvenanceRow>): ProvenanceRow =>
  ({
    scope: { scope: "global" },
    kind: "skill",
    name: "gh",
    harness: "claude",
    at: null,
    origin: { origin: "marketplace", source: "cat", repo: "o/r" },
    summary: null,
    package: { kind: "skill", name: "gh" },
    ...overrides,
  }) as ProvenanceRow;

const ASKED = { kind: "skill" as const, name: "gh" };

// The words for a package with no copy left come from the row a record
// seeded, which core keys by the declaration because there is no file.
// An observed row's words belong to the copy on disk and are read through
// the installation-keyed lookup instead, so this one must not answer from
// them: a row is asked here precisely when no installation of it was seen.
describe("seededSummaryIndex", () => {
  it("answers from a seeded row and from nothing else", () => {
    const cases: [string, ProvenanceRow[], string | null][] = [
      ["a seeded row", [row({ summary: "about gh" })], "about gh"],
      [
        "an observed row",
        [row({ at: "/h/.claude/skills/gh", summary: "about gh" })],
        null,
      ],
      ["a seeded row whose author wrote nothing", [row({})], null],
      [
        "a seeded row the records tie to no package",
        [row({ package: null, summary: "about gh" })],
        null,
      ],
      [
        "another package's words",
        [row({ name: "dev", package: { kind: "skill", name: "dev" } })],
        null,
      ],
      ["no rows at all", [], null],
    ];
    expect(cases).toHaveLength(6);
    for (const [name, rows, summary] of cases)
      expect(seededSummaryIndex(rows)(ASKED), name).toBe(summary);
  });

  // Two places can declare different versions of one package. The first
  // with words speaks, the rule grouping already applies across an
  // installed package's copies.
  it("takes the first place that wrote any", () => {
    const index = seededSummaryIndex([
      row({}),
      row({ scope: { scope: "project", root: "/p" }, summary: "about gh" }),
    ]);
    expect(index(ASKED)).toBe("about gh");
  });
});
