// The default is what runs on every real test file, and no nested run
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
    const rows = [
      { name: "2500", raw: "2500", expected: 2500 },
      {
        name: "largest timer value",
        raw: String(OVERFLOWS_AT - 1),
        expected: OVERFLOWS_AT - 1,
      },
    ];
    expect(
      rows.length,
      "accepted closing-window table is empty",
    ).toBeGreaterThan(0);
    for (const row of rows) {
      expect(resolveClosingWindowMs(row.raw), row.name).toBe(row.expected);
    }
  });

  it("falls back to the default for unusable input", () => {
    const rows = [
      ["unset", undefined],
      ["empty", ""],
      ["not a number", "soon"],
      ["zero", "0"],
      ["a sign typo", "-5000"],
      ["infinite", "1e400"],
      ["past what setTimeout holds", String(OVERFLOWS_AT)],
    ] as const;
    expect(
      rows.length,
      "fallback closing-window table is empty",
    ).toBeGreaterThan(0);
    for (const [name, raw] of rows) {
      expect(resolveClosingWindowMs(raw), name).toBe(DEFAULT_CLOSING_WINDOW_MS);
    }
  });

  it("keeps the shipped default at 50ms", () => {
    expect(DEFAULT_CLOSING_WINDOW_MS).toBe(50);
  });
});
