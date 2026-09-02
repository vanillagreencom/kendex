// The default is what runs on all 124 real test files, and no nested run
// exercises it: the one control whose verdict turns on a window passes its
// own. So it is pinned here, on the resolver alone, with no timing.
import { describe, expect, it } from "vitest";
import {
  DEFAULT_CLOSING_WINDOW_MS,
  resolveClosingWindowMs,
} from "./closing-window";

const OVERFLOWS_AT = 2 ** 31;

describe("resolveClosingWindowMs", () => {
  it("honours what a run asks for", () => {
    expect(resolveClosingWindowMs("2500")).toBe(2500);
    expect(resolveClosingWindowMs(String(OVERFLOWS_AT - 1))).toBe(
      OVERFLOWS_AT - 1,
    );
  });

  it.for([
    ["unset", undefined],
    ["empty", ""],
    ["not a number", "soon"],
    ["zero", "0"],
    ["a sign typo", "-5000"],
    ["infinite", "1e400"],
    ["past what setTimeout holds", String(OVERFLOWS_AT)],
  ] as const)("falls back to the default when %s", ([, raw]) => {
    expect(resolveClosingWindowMs(raw)).toBe(DEFAULT_CLOSING_WINDOW_MS);
  });

  it("keeps the shipped default at 50ms", () => {
    expect(DEFAULT_CLOSING_WINDOW_MS).toBe(50);
  });
});
