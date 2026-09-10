import { describe, expect, it } from "vitest";
import { PREVIEW_SUMMARY_CHARS, previewSummary } from "./package-summary";

// The bound decides two things at once: what a preview draws, and whether
// More appears under it. One rule answers both, so a preview can never
// leave text out without saying so.
describe("previewSummary", () => {
  const word = "kendex ";
  const long = word.repeat(
    Math.ceil((PREVIEW_SUMMARY_CHARS + 40) / word.length),
  );

  it("shows a summary whole up to the bound and cuts at a word past it", () => {
    const rows = [
      {
        name: "short",
        input: "Stops a bare cd.",
        shown: "Stops a bare cd.",
        truncated: false,
      },
      {
        name: "trimmed",
        input: "  Stops a bare cd.  ",
        shown: "Stops a bare cd.",
        truncated: false,
      },
      {
        name: "at the bound",
        input: "a".repeat(PREVIEW_SUMMARY_CHARS),
        shown: "a".repeat(PREVIEW_SUMMARY_CHARS),
        truncated: false,
      },
      {
        name: "one past the bound",
        input: `${"a".repeat(PREVIEW_SUMMARY_CHARS)} b`,
        shown: `${"a".repeat(PREVIEW_SUMMARY_CHARS)}…`,
        truncated: true,
      },
      {
        name: "one long word",
        input: "a".repeat(PREVIEW_SUMMARY_CHARS + 10),
        shown: `${"a".repeat(PREVIEW_SUMMARY_CHARS)}…`,
        truncated: true,
      },
    ] as const;
    expect(rows.length, "preview bound table is empty").toBeGreaterThan(0);
    for (const row of rows) {
      const result = previewSummary(row.input);
      expect(result.shown, row.name).toBe(row.shown);
      expect(result.truncated, row.name).toBe(row.truncated);
    }
  });

  // A summary is ordinary author text and an emoji is ordinary in one. It
  // is two of the units a string indexes in, so a bound counted in units
  // can land between its halves; nothing before the bound is a space, so
  // there is no word boundary to fall back to and hide it.
  it("never cuts a character in half", () => {
    const { shown, truncated } = previewSummary(
      `${"a".repeat(PREVIEW_SUMMARY_CHARS - 1)}\u{1F600} and more`,
    );
    expect(truncated).toBe(true);
    expect(shown).toBe(`${"a".repeat(PREVIEW_SUMMARY_CHARS - 1)}\u{1F600}…`);
    // Said again as the property, so a rewritten expectation cannot pass
    // with half a character in it: no unpaired surrogate anywhere.
    expect(
      /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/.test(
        shown,
      ),
    ).toBe(false);
  });

  it("never ends a cut mid-word and never keeps more than the bound", () => {
    const { shown, truncated } = previewSummary(long);
    expect(truncated).toBe(true);
    expect(shown.length).toBeLessThanOrEqual(PREVIEW_SUMMARY_CHARS + 1);
    expect(shown.endsWith("…")).toBe(true);
    expect(shown.slice(0, -1).endsWith(" ")).toBe(false);
  });
});
