import { describe, expect, it } from "vitest";
import { diffHarness, type PackageView } from "./use-package-data";

describe("diffHarness", () => {
  it("reads the comparison's rendering or the primary one", () => {
    const edited: PackageView = {
      mode: "diff",
      from: "a",
      to: "installed",
      fromLabel: "v1",
      toLabel: "your edits in OpenCode",
      harness: "opencode",
    };
    const rows: {
      name: string;
      view: PackageView;
      primary: "claude" | null;
      expected: "opencode" | "claude" | null;
    }[] = [
      {
        name: "explicit diff rendering",
        view: edited,
        primary: "claude",
        expected: "opencode",
      },
      {
        name: "diff fallback",
        view: { ...edited, harness: undefined },
        primary: "claude",
        expected: "claude",
      },
      {
        name: "files view",
        view: { mode: "files", file: null },
        primary: "claude",
        expected: "claude",
      },
      {
        name: "files without a primary",
        view: { mode: "files", file: null },
        primary: null,
        expected: null,
      },
    ];
    expect(rows).toHaveLength(4);
    for (const { name, view, primary, expected } of rows)
      expect(diffHarness(view, primary), name).toBe(expected);
  });
});
