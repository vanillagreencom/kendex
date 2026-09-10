import { describe, expect, it } from "vitest";
import type { ObservedItem, ScanResult } from "@/bindings";
import { observed } from "@/test/observed";
import { scopeChoices } from "./derive";

function result(roots: string[]): ScanResult {
  const items: ObservedItem[] = roots.map((root) =>
    observed({
      kind: "skill",
      name: "deploy",
      harness: "claude",
      scope: { scope: "project", root },
      path: `${root}/.claude/skills/deploy`,
      fileState: { state: "dir" },
      enabled: true,
      origin: null,
      description: null,
      tags: [],
      modifiedAt: null,
      vendor: null,
    }),
  );
  return {
    harnesses: [],
    items,
    missingProjects: [],
    readProjects: [],
    warnings: [],
  };
}

describe("scopeChoices", () => {
  it("sorts distinct installed and selected project roots", () => {
    const rows: {
      name: string;
      scan: ScanResult | null;
      selection: Parameters<typeof scopeChoices>[1];
      expected: string[];
    }[] = [
      {
        name: "installed roots",
        scan: result(["/b", "/a", "/a"]),
        selection: "all",
        expected: ["/a", "/b"],
      },
      {
        name: "selected empty project",
        scan: result(["/z"]),
        selection: { project: "/empty" },
        expected: ["/empty", "/z"],
      },
      {
        name: "selected before scan",
        scan: null,
        selection: { project: "/empty" },
        expected: ["/empty"],
      },
      {
        name: "selected installed project",
        scan: result(["/a"]),
        selection: { project: "/a" },
        expected: ["/a"],
      },
    ];
    expect(rows.length, "scope choice table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(scopeChoices(row.scan, row.selection), row.name).toEqual(
        row.expected,
      );
  });
});
