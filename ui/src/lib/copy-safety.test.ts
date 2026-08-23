import { describe, expect, it } from "vitest";
import {
  CATALOG_LAYOUT_CLEAN,
  PREINSTALL_SAFETY_CAVEAT,
  publisherSettledLabel,
  publisherSettledNote,
  SAFETY_DOT_UNCHECKED,
  SAFETY_SECTION_EXPLAINER,
  safetyDotWords,
  settledSummaryLead,
} from "./copy-safety";
import { VERDICT_LABELS } from "./labels";

describe("settledSummaryLead", () => {
  // The second argument is optional, so a caller that forgets it drops the
  // publisher clause with nothing else to catch it. Both spellings pinned.
  it("names the publisher's share only when there is one", () => {
    expect(settledSummaryLead(3)).toBe("3 findings already decided");
    expect(settledSummaryLead(1)).toBe("1 finding already decided");
    expect(settledSummaryLead(3, 2)).toBe(
      "3 findings already decided (2 by the publisher)",
    );
    expect(settledSummaryLead(3, 0)).toBe("3 findings already decided");
  });
});

describe("the publisher's own decisions", () => {
  it("says whose call it was, and never lets it read as the reader's", () => {
    expect(publisherSettledLabel(1)).toBe(
      "1 finding the publisher already reviewed",
    );
    expect(publisherSettledLabel(4)).toBe(
      "4 findings the publisher already reviewed",
    );
    const note = publisherSettledNote(
      "vanillagreencom/kendex",
      "intended",
      "2 days ago",
    );
    expect(note).toBe(
      "vanillagreencom/kendex reviewed this 2 days ago — does this on purpose",
    );
    expect(publisherSettledNote("owner/repo", "wrong-call", null)).toBe(
      "owner/repo reviewed this — not actually a problem",
    );
  });
});

describe("what a verdict is allowed to claim", () => {
  // Everything a person reads where a verdict belongs, the words that stand
  // in before one arrives included. A pass means "nothing was matched in what
  // we read", so none of these may promise more. The banned words are matched
  // as plain substrings, which the copy affords by never reaching for them —
  // not even in a negated form.
  const besideAVerdict = [
    ...Object.values(VERDICT_LABELS),
    PREINSTALL_SAFETY_CAVEAT,
    SAFETY_SECTION_EXPLAINER,
    CATALOG_LAYOUT_CLEAN,
    safetyDotWords("clean", 100),
    SAFETY_DOT_UNCHECKED,
  ];

  it("never claims more than the check established", () => {
    const copy = besideAVerdict.join(" ").toLowerCase();
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

  it("discloses that the read is partial wherever it shows a verdict", () => {
    // The list's dot is the whole verdict on a row that installs from
    // there, so its words carry the caveat the number cannot.
    expect(safetyDotWords("warn", 60)).toBe(
      "Installs, with a warning · 60/100. An automated check for risky patterns, not a review. It can miss things, and a large skill is read only in part.",
    );
    expect(PREINSTALL_SAFETY_CAVEAT).toBe(
      "An automated check for risky patterns, not a review. It can miss things, and a large skill is read only in part.",
    );
    expect(SAFETY_SECTION_EXPLAINER).toBe(
      "kendex looks for risky patterns in each package before it installs. It is an automated check rather than a review. It can miss things, and a large skill is read only in part.",
    );
  });

  it("carries the caveat before any result has landed, claiming neither way", () => {
    // The row installs whether or not its score has arrived, so the words
    // that stand in for one say the check has not answered and repeat what
    // the check is worth — without borrowing a verdict's language.
    expect(SAFETY_DOT_UNCHECKED).toBe(
      "Not checked yet. An automated check for risky patterns, not a review. It can miss things, and a large skill is read only in part.",
    );
    for (const label of Object.values(VERDICT_LABELS)) {
      expect(SAFETY_DOT_UNCHECKED).not.toContain(label);
    }
    expect(SAFETY_DOT_UNCHECKED).not.toMatch(/\d+\/100/);
  });

  it("keeps the About tab's clean line about layout, not about content", () => {
    expect(CATALOG_LAYOUT_CLEAN).toBe(
      "Nothing wrong with how this catalog is put together.",
    );
  });
});
