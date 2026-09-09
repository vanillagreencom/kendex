import { describe, expect, it } from "vitest";
import { type Comparison, diffHarness } from "./use-package-data";

describe("diffHarness", () => {
  it("reads the comparison's rendering or the primary one", () => {
    const edited: Comparison = {
      from: "a",
      to: "installed",
      fromLabel: "v1",
      toLabel: "your edits in OpenCode",
      harness: "opencode",
    };
    const rows: {
      name: string;
      comparison: Comparison | null;
      primary: "claude" | null;
      expected: "opencode" | "claude" | null;
    }[] = [
      {
        name: "explicit comparison rendering",
        comparison: edited,
        primary: "claude",
        expected: "opencode",
      },
      {
        name: "comparison fallback",
        comparison: { ...edited, harness: undefined },
        primary: "claude",
        expected: "claude",
      },
      {
        name: "no comparison open",
        comparison: null,
        primary: "claude",
        expected: "claude",
      },
      {
        name: "no comparison and no primary",
        comparison: null,
        primary: null,
        expected: null,
      },
    ];
    expect(rows).toHaveLength(4);
    for (const { name, comparison, primary, expected } of rows)
      expect(diffHarness(comparison, primary), name).toBe(expected);
  });
});
