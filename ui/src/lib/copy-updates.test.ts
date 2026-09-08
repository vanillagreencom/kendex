import { describe, expect, it } from "vitest";
import { lastCheckedLabel, NEVER_CHECKED } from "./copy-updates";

// The overview reports Unix seconds, while the UI clock uses milliseconds.
const SECONDS = 1_700_000_000;
const at = (offsetMs: number): number => SECONDS * 1000 + offsetMs;

describe("how old the update standing is", () => {
  it("dates the answer from the last successful fetch", () => {
    const rows = [
      { name: "just fetched", offset: 0, expected: "Last checked just now" },
      { name: "minutes", offset: 3 * 60_000, expected: "Last checked 3m ago" },
      { name: "hours", offset: 5 * 3_600_000, expected: "Last checked 5h ago" },
      { name: "days", offset: 5 * 86_400_000, expected: "Last checked 5d ago" },
    ];
    expect(rows.length, "fetch age table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(lastCheckedLabel(SECONDS, at(row.offset)), row.name).toBe(
        row.expected,
      );
  });

  it("distinguishes a scope that was never fetched", () => {
    expect(lastCheckedLabel(null, at(0))).toBe(NEVER_CHECKED);
    expect(NEVER_CHECKED).not.toContain("ago");
  });
});
