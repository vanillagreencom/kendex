import { beforeEach, describe, expect, it } from "vitest";
import type { AuditView } from "@/bindings";
import { ADOPTABLE } from "@/lib/adoptable";
import { deriveProblems, useProblemsStore } from "./problems";

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

describe("the error dialog's join rule", () => {
  beforeEach(() => {
    useProblemsStore.getState().closeError();
  });

  const fail = (title: string) =>
    useProblemsStore.getState().showError({ title, message: `${title} why` });
  const close = () => useProblemsStore.getState().closeError();

  // Every state a failure can arrive in: over a closed dialog, over one
  // still up, and over one the person dismissed. Two loops' failures in
  // flight at once are the same as one loop's: nothing tells them apart.
  it("keeps every failure said until the person dismisses the dialog", () => {
    const rows: { name: string; act: () => void; shown: string[] }[] = [
      { name: "over a closed dialog", act: () => fail("a"), shown: ["a"] },
      {
        name: "over a dialog still up",
        act: () => {
          fail("a");
          fail("b");
          fail("c");
        },
        shown: ["a", "b", "c"],
      },
      {
        name: "after the dialog was dismissed",
        act: () => {
          fail("a");
          close();
          fail("b");
        },
        shown: ["b"],
      },
      {
        name: "joined, then dismissed, then failed again",
        act: () => {
          fail("a");
          fail("b");
          close();
          fail("c");
          fail("d");
        },
        shown: ["c", "d"],
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      close();
      row.act();
      const { dialog } = useProblemsStore.getState();
      expect(dialog.open, row.name).toBe(true);
      expect(
        [dialog, ...dialog.joined].map((one) => [one.title, one.message]),
        row.name,
      ).toEqual(row.shown.map((title) => [title, `${title} why`]));
    }
  });
});
