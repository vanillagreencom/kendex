import { describe, expect, it } from "vitest";
import { acceptedSummary } from "./terms";

describe("what the About row says the terms record holds", () => {
  it("names the version and the date it was accepted on", () => {
    expect(
      acceptedSummary({
        ask: false,
        accepted: { version: 1, "accepted-at": "2026-09-06T10:11:12Z" },
      }),
    ).toBe("version 1, accepted 2026-09-06");
  });

  it("says nothing is accepted only when the record is read and empty", () => {
    expect(acceptedSummary({ ask: true, accepted: null })).toBe("not accepted");
  });

  // The must-fail half. Nothing read is not the same as nothing accepted,
  // and telling a person who accepted months ago that they did not is the
  // one thing this row must never do.
  it("claims nothing while the record is unread", () => {
    expect(acceptedSummary(null)).toBe("…");
  });
});
