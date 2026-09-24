import { describe, expect, it } from "vitest";
import type { ProblemKind } from "@/stores/problems";
import { PROBLEM_LEADS, PROBLEM_STEPS } from "./error-copy";

describe("problem lead presence", () => {
  it("omits a lead when the failure names no single file", () => {
    const kinds: ProblemKind[] = ["schema-too-new", "other", "scan-failure"];
    expect(kinds.length, "absent problem lead table is empty").toBeGreaterThan(
      0,
    );
    for (const kind of kinds) expect(PROBLEM_LEADS[kind], kind).toBeNull();
  });
});

describe("lock recovery ownership", () => {
  it("leaves the recovery sequence to the engine message", () => {
    const steps = PROBLEM_STEPS["lock-corrupt"];
    expect(steps).toHaveLength(1);
    expect(steps.join(" ")).not.toMatch(/move|apply|hooks\.json|hooks\//i);
  });
});
