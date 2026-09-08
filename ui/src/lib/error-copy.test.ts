import { describe, expect, it } from "vitest";
import type { ProblemKind } from "@/stores/problems";
import { PROBLEM_LEADS, problemsFooterLabel } from "./error-copy";

describe("problemsFooterLabel", () => {
  it("formats the supplied problem count", () => {
    const rows = [
      { count: 0, expected: "0 problems" },
      { count: 1, expected: "1 problem" },
      { count: 3, expected: "3 problems" },
    ];
    expect(rows.length, "problem count table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(problemsFooterLabel(row.count), String(row.count)).toBe(
        row.expected,
      );
  });
});

describe("problem lead presence", () => {
  it("omits a lead when the failure names no single file", () => {
    const kinds: ProblemKind[] = ["schema-too-new", "other", "scan-failure"];
    expect(kinds.length, "absent problem lead table is empty").toBeGreaterThan(
      0,
    );
    for (const kind of kinds) expect(PROBLEM_LEADS[kind], kind).toBeNull();
  });
});
