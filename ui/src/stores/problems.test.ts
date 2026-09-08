import { describe, expect, it } from "vitest";
import type { AuditView } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { deriveProblems } from "./problems";

const globalScope = { scope: "global" as const };
const projectScope = { scope: "project" as const, root: "/home/dana/api" };

function view(overrides: Partial<AuditView>): AuditView {
  return {
    scope: globalScope,
    drift: [],
    plan: [],
    notes: [],
    warnings: [],
    safety: [],
    adoptable: ADOPTABLE,
    exits: [],
    error: null,
    ...overrides,
  };
}

describe("deriveProblems", () => {
  it("projects each combination of audit and scan errors", () => {
    const rows = [
      {
        name: "healthy scan and views",
        views: [view({})],
        scan: null,
        expected: [],
      },
      {
        name: "scoped audit error",
        views: [
          view({}),
          view({
            scope: projectScope,
            error: { kind: "lock-corrupt", message: "not valid JSON" },
          }),
        ],
        scan: null,
        expected: [
          {
            key: "/home/dana/api",
            scope: projectScope,
            kind: "lock-corrupt",
            message: "not valid JSON",
          },
        ],
      },
      {
        name: "scan failure",
        views: [view({})],
        scan: "boom",
        expected: [
          { key: "scan", scope: null, kind: "scan-failure", message: "boom" },
        ],
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows)
      expect(deriveProblems(row.views, row.scan), row.name).toEqual(
        row.expected,
      );
  });

  it("reports both an audit error and a scan failure at once", () => {
    const errored = view({
      error: { kind: "manifest-invalid", message: "bad toml" },
    });
    const problems = deriveProblems([errored], "scan broke");
    expect(problems).toHaveLength(2);
    expect(problems.map((p) => p.kind)).toEqual([
      "manifest-invalid",
      "scan-failure",
    ]);
  });
});
