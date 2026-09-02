import { describe, expect, it } from "vitest";
import { exactTime, relativeTime } from "./relative-time";

describe("relativeTime", () => {
  it("reads as just now under a minute", () => {
    expect(relativeTime(0, 45_000)).toBe("just now");
  });

  it("rounds to whole minutes", () => {
    expect(relativeTime(0, 2 * 60_000)).toBe("2m ago");
  });

  it("rounds to whole hours once past 60 minutes", () => {
    expect(relativeTime(0, 3 * 60 * 60_000)).toBe("3h ago");
  });

  it("rounds to whole days once past 24 hours", () => {
    expect(relativeTime(0, 2 * 24 * 60 * 60_000)).toBe("2d ago");
  });
});

const DAY = 24 * 60 * 60_000;

// Both marketplace surfaces date a commit with this, and a catalog's
// packages are routinely years old.
describe("relativeTime over the ranges a commit date reaches", () => {
  it("keeps counting days up to a month", () => {
    expect(relativeTime(0, 29 * DAY)).toBe("29d ago");
  });

  it("moves to months rather than a three-digit day count", () => {
    expect(relativeTime(0, 30 * DAY)).toBe("1mo ago");
    expect(relativeTime(0, 100 * DAY)).toBe("3mo ago");
  });

  it("never says twelve months, which is a year", () => {
    expect(relativeTime(0, 364 * DAY)).toBe("11mo ago");
    expect(relativeTime(0, 365 * DAY)).toBe("1y ago");
  });

  it("floors years, so a year and a half is not aged to two", () => {
    expect(relativeTime(0, 548 * DAY)).toBe("1y ago");
    expect(relativeTime(0, 731 * DAY)).toBe("2y ago");
  });
});

// A year or a month reading loses the date it came from, so every surface
// showing one keeps the exact moment on its element. This is what the
// surfaces holding a timestamp rather than the original string put there.
describe("the exact moment behind a reading", () => {
  it("is ISO-8601 in UTC", () => {
    expect(exactTime(Date.UTC(2024, 0, 2, 3, 4, 5))).toBe(
      "2024-01-02T03:04:05.000Z",
    );
  });
});
