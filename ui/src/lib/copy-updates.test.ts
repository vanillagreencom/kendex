import { describe, expect, it } from "vitest";
import { lastCheckedLabel, NEVER_CHECKED } from "./copy-updates";

// The overview reports Unix seconds; every relative wording below has to
// come off that scale, not off milliseconds read as seconds.
const SECONDS = 1_700_000_000;
const at = (offsetMs: number): number => SECONDS * 1000 + offsetMs;

describe("how old the update standing is", () => {
  it("dates the answer from the last successful fetch", () => {
    expect(lastCheckedLabel(SECONDS, at(0))).toBe("Last checked just now");
    expect(lastCheckedLabel(SECONDS, at(3 * 60_000))).toBe(
      "Last checked 3m ago",
    );
    expect(lastCheckedLabel(SECONDS, at(5 * 3_600_000))).toBe(
      "Last checked 5h ago",
    );
    expect(lastCheckedLabel(SECONDS, at(5 * 86_400_000))).toBe(
      "Last checked 5d ago",
    );
  });

  // The whole point of the hint: a scope nothing has fetched must not read
  // as a check that just ran, which is what an unlabelled clean page does.
  it("says so when nothing has ever been fetched", () => {
    expect(lastCheckedLabel(null, at(0))).toBe(NEVER_CHECKED);
    expect(NEVER_CHECKED).not.toContain("ago");
  });
});
