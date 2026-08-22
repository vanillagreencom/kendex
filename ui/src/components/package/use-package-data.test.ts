import { describe, expect, it } from "vitest";
import { diffHarness, openingTab, openingView } from "./use-package-data";

// What the package page shows on arrival is decided here, so the mark that
// sent the reader is the thing they see when they land.
describe("openingView", () => {
  it("opens the comparison a Preview link asked for", () => {
    expect(
      openingView({ mode: "diff", from: "1111111111", to: "2222222222" }),
    ).toEqual({
      mode: "diff",
      from: "1111111111",
      to: "2222222222",
      fromLabel: "1111111",
      toLabel: "2222222",
    });
  });

  it("opens the files when nothing asked for anything else", () => {
    expect(openingView(null)).toEqual({ mode: "files", file: null });
    expect(openingView({ mode: "customize" })).toEqual({
      mode: "files",
      file: null,
    });
  });
});

describe("openingTab", () => {
  it("opens the Customize tab when a settings mark sent the reader", () => {
    expect(openingTab({ mode: "customize" })).toBe("customize");
  });

  it("opens the overview otherwise", () => {
    expect(openingTab(null)).toBe("overview");
    expect(openingTab({ mode: "diff", from: "a", to: "b" })).toBe("overview");
  });
});

describe("diffHarness", () => {
  it("reads the tool the comparison names, else the primary install", () => {
    const diff = {
      mode: "diff",
      from: "a",
      to: "b",
      fromLabel: "a",
      toLabel: "b",
    } as const;
    expect(diffHarness({ ...diff, harness: "codex" }, "claude")).toBe("codex");
    expect(diffHarness(diff, "claude")).toBe("claude");
    expect(diffHarness({ mode: "files", file: null }, "claude")).toBe("claude");
  });
});
