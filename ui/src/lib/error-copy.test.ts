import { describe, expect, it } from "vitest";
import type { ProblemKind } from "@/stores/problems";
import { PROBLEM_LEADS } from "./error-copy";

describe("problem lead presence", () => {
  it("omits a lead when the failure names no single file", () => {
    const kinds: ProblemKind[] = ["schema-too-new", "other", "scan-failure"];
    expect(kinds.length, "absent problem lead table is empty").toBeGreaterThan(
      0,
    );
    for (const kind of kinds) expect(PROBLEM_LEADS[kind], kind).toBeNull();
  });
});
