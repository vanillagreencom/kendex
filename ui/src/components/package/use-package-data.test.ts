import { describe, expect, it } from "vitest";
import { diffHarness } from "./use-package-data";

describe("diffHarness", () => {
  it("reads the rendering the comparison names, else the primary one", () => {
    const edited = {
      mode: "diff" as const,
      from: "a",
      to: "installed",
      fromLabel: "v1",
      toLabel: "your edits in OpenCode",
      harness: "opencode" as const,
    };
    expect(diffHarness(edited, "claude")).toBe("opencode");
    expect(diffHarness({ ...edited, harness: undefined }, "claude")).toBe(
      "claude",
    );
    expect(diffHarness({ mode: "files", file: null }, "claude")).toBe("claude");
    expect(diffHarness({ mode: "files", file: null }, null)).toBeNull();
  });
});
