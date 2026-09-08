import { describe, expect, it } from "vitest";
import { exactTime, relativeTime } from "./relative-time";

const DAY = 24 * 60 * 60_000;

describe("relativeTime", () => {
  it("formats elapsed time without rounding a partial year up", () => {
    const rows = [
      { name: "under a minute", elapsed: 45_000, expected: "just now" },
      { name: "minutes", elapsed: 2 * 60_000, expected: "2m ago" },
      { name: "hours", elapsed: 3 * 60 * 60_000, expected: "3h ago" },
      { name: "days", elapsed: 2 * DAY, expected: "2d ago" },
      { name: "before a month", elapsed: 29 * DAY, expected: "29d ago" },
      { name: "one month", elapsed: 30 * DAY, expected: "1mo ago" },
      { name: "several months", elapsed: 100 * DAY, expected: "3mo ago" },
      { name: "before a year", elapsed: 364 * DAY, expected: "11mo ago" },
      { name: "one year", elapsed: 365 * DAY, expected: "1y ago" },
      { name: "partial second year", elapsed: 548 * DAY, expected: "1y ago" },
      { name: "two years", elapsed: 731 * DAY, expected: "2y ago" },
    ];
    expect(rows.length, "elapsed time table is empty").toBeGreaterThan(0);
    for (const row of rows)
      expect(relativeTime(0, row.elapsed), row.name).toBe(row.expected);
  });
});

describe("exactTime", () => {
  it("is ISO-8601 in UTC", () => {
    expect(exactTime(Date.UTC(2024, 0, 2, 3, 4, 5))).toBe(
      "2024-01-02T03:04:05.000Z",
    );
  });
});
