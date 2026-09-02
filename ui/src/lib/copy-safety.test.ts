import { describe, expect, it } from "vitest";
import type { Finding } from "@/bindings";
import {
  installedScoreWords,
  SAFETY_CAVEAT,
  SAFETY_CHECK_FAILED,
  SAFETY_DOT_UNCHECKED,
  safetyDotWords,
  safetyHeadline,
  severityTone,
  staleSafetyNote,
} from "./copy-safety";

const finding = (severity: Finding["severity"]): Finding => ({
  rule: "dangerous-commands",
  severity,
  location: "SKILL.md",
  line: 3,
  message: "runs a shell command that deletes files without asking",
  remediation: "scope the command to a specific path, or drop it",
});

describe("what a score is allowed to claim", () => {
  // Everything a person reads where a score belongs, the words that stand
  // in before one arrives included. A clean read means "nothing was matched
  // in what we read", so none of these may promise more. The banned words
  // are matched as plain substrings, which the copy affords by never
  // reaching for them — not even in a negated form.
  const besideAScore = [
    SAFETY_CAVEAT,
    safetyDotWords(100, 0, []),
    safetyDotWords(100, 3, []),
    safetyHeadline([], 0),
    safetyHeadline([], 3),
    installedScoreWords(100, 0, []),
    installedScoreWords(100, 0, [], true),
    SAFETY_CHECK_FAILED,
    staleSafetyNote,
    SAFETY_DOT_UNCHECKED,
  ];

  it("never claims more than the check established", () => {
    const copy = besideAScore.join(" ").toLowerCase();
    for (const banned of [
      "safe",
      "verified",
      "verifies",
      "approved",
      "trusted",
      "vetted",
      "endorse",
      "guarantee",
    ]) {
      expect(copy).not.toContain(banned);
    }
  });

  it("discloses that the read is partial wherever it shows a score", () => {
    // The list's dot is the whole reading on a row that installs from
    // there, so its words carry the caveat the number cannot.
    expect(safetyDotWords(60, 0, [finding("high")])).toBe(
      "Important · 60/100. An automated check for risky patterns, not a review. It can miss things, and a package too large to read is not checked at all.",
    );
    expect(SAFETY_CAVEAT).toBe(
      "An automated check for risky patterns, not a review. It can miss things, and a package too large to read is not checked at all.",
    );
  });

  it("carries the caveat before any result has landed, claiming neither way", () => {
    // The row installs whether or not its score has arrived, so the words
    // that stand in for one say the check has not answered and repeat what
    // the check is worth — without a number that reads as a result.
    expect(SAFETY_DOT_UNCHECKED).toBe(
      "Not checked yet. An automated check for risky patterns, not a review. It can miss things, and a package too large to read is not checked at all.",
    );
    expect(SAFETY_DOT_UNCHECKED).not.toMatch(/\d+\/100/);
  });
});

describe("what a clean score is entitled to claim", () => {
  it("says the read was partial when a rule was given nothing to read", () => {
    expect(safetyDotWords(100, 1, [])).toContain("Not fully checked");
    expect(safetyDotWords(100, 12, [])).toContain("Not fully checked");
  });

  it("stands on the number alone when every rule read something", () => {
    expect(safetyDotWords(100, 0, [])).not.toContain("Not fully checked");
  });

  it("lets findings speak for themselves over a partial read", () => {
    expect(safetyDotWords(60, 3, [finding("high")])).not.toContain(
      "Not fully checked",
    );
  });
});

describe("what the dot's words say about severity", () => {
  // The dot's colour answers for the worst finding, so its words name that
  // severity too: never colour alone.
  it("names the worst finding's severity in the app's own words", () => {
    expect(
      safetyDotWords(40, 0, [finding("low"), finding("critical")]),
    ).toMatch(/^Serious · 40\/100\./);
    expect(safetyDotWords(90, 0, [finding("low")])).toMatch(/^Minor · /);
    expect(safetyDotWords(100, 0, [])).not.toContain(" · ");
  });
});

describe("severityTone", () => {
  // The dot's colour is never the only signal — the words beside it carry
  // the number — but the colour still has to answer for the worst finding.
  it("is critical for any critical finding, warning for the rest, good for none", () => {
    expect(severityTone([finding("low"), finding("critical")])).toBe(
      "critical",
    );
    expect(severityTone([finding("low"), finding("high")])).toBe("warning");
    expect(severityTone([])).toBe("good");
  });
});

describe("the line under a score", () => {
  it("names the worst severity and how many, in the app's own words", () => {
    expect(safetyHeadline([finding("low"), finding("critical")], 0)).toBe(
      "Serious · 2 findings",
    );
    expect(safetyHeadline([finding("high")], 0)).toBe("Important · 1 finding");
  });

  // A clean read and a partial one are different claims: one says nothing
  // was matched, the other that nothing was matched in what was reached.
  it("keeps a partial read apart from a clean one", () => {
    expect(safetyHeadline([], 0)).toBe("Nothing found");
    expect(safetyHeadline([], 2)).toBe("Nothing found in what was read");
  });

  // The Updates page's rows are about a version that is not installed yet.
  // A bare number there would be read as the one the update would earn.
  it("says which copy the Updates page's score is of", () => {
    const words = installedScoreWords(58, 0, [finding("high")]);
    expect(words).toContain("installed now");
    expect(words).toContain("58/100");
    expect(words).toContain("Important");
  });

  // A number kept from before a failed check is not what the files say now,
  // and presenting it as current is a claim nothing has made.
  it("stops calling a kept reading the copy installed now", () => {
    const kept = installedScoreWords(58, 0, [finding("high")], true);
    expect(kept).toContain("58/100");
    expect(kept).toContain("couldn't run");
    expect(kept).not.toContain("installed now");
  });
});
