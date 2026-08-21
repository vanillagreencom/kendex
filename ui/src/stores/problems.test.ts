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
    heldBack: [],
    queued: [],
    error: null,
    ...overrides,
  };
}

describe("deriveProblems", () => {
  it("is empty when every view is error-free and the scan is healthy", () => {
    expect(deriveProblems([view({})], null)).toEqual([]);
  });

  it("turns a view with an error into a scoped problem", () => {
    const errored = view({
      scope: projectScope,
      error: { kind: "lock-corrupt", message: "not valid JSON" },
    });

    const problems = deriveProblems([view({}), errored], null);

    expect(problems).toEqual([
      {
        key: "/home/dana/api",
        scope: projectScope,
        kind: "lock-corrupt",
        message: "not valid JSON",
      },
    ]);
  });

  it("adds one scope-less problem for a failing scan", () => {
    const problems = deriveProblems([view({})], "boom");

    expect(problems).toEqual([
      { key: "scan", scope: null, kind: "scan-failure", message: "boom" },
    ]);
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
