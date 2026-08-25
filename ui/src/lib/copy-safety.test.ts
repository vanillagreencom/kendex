import { describe, expect, it } from "vitest";
import type { Finding } from "@/bindings";
import {
  CATALOG_LAYOUT_CLEAN,
  PREINSTALL_SAFETY_CAVEAT,
  SAFETY_DOT_UNCHECKED,
  SAFETY_SECTION_EXPLAINER,
  safetyDotWords,
  severityTone,
} from "./copy-safety";

const finding = (severity: Finding["severity"]): Finding => ({
  rule: "dangerous-commands",
  severity,
  location: "SKILL.md:3",
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
    PREINSTALL_SAFETY_CAVEAT,
    SAFETY_SECTION_EXPLAINER,
    CATALOG_LAYOUT_CLEAN,
    safetyDotWords(100, 0, []),
    safetyDotWords(100, 3, []),
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
      "60/100. An automated check for risky patterns, not a review. It can miss things, and a package too large to read is not checked at all.",
    );
    expect(PREINSTALL_SAFETY_CAVEAT).toBe(
      "An automated check for risky patterns, not a review. It can miss things, and a package too large to read is not checked at all.",
    );
    expect(SAFETY_SECTION_EXPLAINER).toBe(
      "kendex looks for risky patterns in each package. It is an automated check rather than a review, it can miss things, and a package too large to read is not checked at all. Nothing is held back over it.",
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

  it("keeps the About tab's clean line about layout, not about content", () => {
    expect(CATALOG_LAYOUT_CLEAN).toBe(
      "Nothing wrong with how this catalog is put together.",
    );
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
