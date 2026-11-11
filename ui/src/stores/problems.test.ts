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
  const inOneRun = (work: () => Promise<void>) =>
    useProblemsStore.getState().inOneRun(work);

  // Every state a failure can arrive in: with or without a run, over a
  // closed dialog, over one the run opened, and over one the run did not.
  it("joins a failure only to the dialog its own run opened", async () => {
    const rows: {
      name: string;
      act: () => Promise<void>;
      shown: string[];
    }[] = [
      {
        name: "outside a run, over a closed dialog",
        act: async () => fail("a"),
        shown: ["a"],
      },
      {
        name: "outside a run, over an open dialog",
        act: async () => {
          fail("a");
          fail("b");
        },
        shown: ["b"],
      },
      {
        name: "in a run, over a dialog it opened",
        act: () =>
          inOneRun(async () => {
            fail("a");
            fail("b");
            fail("c");
          }),
        shown: ["a", "b", "c"],
      },
      {
        name: "in a run, over a dialog up before it began",
        act: async () => {
          fail("a");
          await inOneRun(async () => {
            fail("b");
            fail("c");
          });
        },
        shown: ["b", "c"],
      },
      {
        name: "in a run, after its dialog was dismissed",
        act: () =>
          inOneRun(async () => {
            fail("a");
            useProblemsStore.getState().closeError();
            fail("b");
          }),
        shown: ["b"],
      },
      {
        name: "in a run inside a run",
        act: () =>
          inOneRun(async () => {
            fail("a");
            await inOneRun(async () => fail("b"));
            fail("c");
          }),
        shown: ["a", "b", "c"],
      },
      {
        name: "after the run ended",
        act: async () => {
          await inOneRun(async () => fail("a"));
          fail("b");
        },
        shown: ["b"],
      },
    ];
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      useProblemsStore.getState().closeError();
      await row.act();
      const { dialog } = useProblemsStore.getState();
      expect(dialog.open, row.name).toBe(true);
      expect(
        [dialog, ...dialog.joined].map((one) => [one.title, one.message]),
        row.name,
      ).toEqual(row.shown.map((title) => [title, `${title} why`]));
    }
  });

  it("ends the run when its work throws", async () => {
    await expect(
      inOneRun(async () => {
        throw new Error("transport");
      }),
    ).rejects.toThrow("transport");
    fail("a");
    fail("b");

    expect(useProblemsStore.getState().dialog.joined).toEqual([]);
  });
});
