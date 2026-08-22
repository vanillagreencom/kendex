import { describe, expect, it } from "vitest";
import {
  CATALOG_LAYOUT_CLEAN,
  PREINSTALL_SAFETY_CAVEAT,
  publisherSettledLabel,
  publisherSettledNote,
  SAFETY_SECTION_EXPLAINER,
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
  // Everything a person reads beside a scan result. A pass means "nothing
  // was matched in what we read", so none of these may promise more: kendex
  // does not write, review or vouch for a catalog's packages. The
  // disclaimers below say "write or review" rather than "verify" precisely
  // so this list needs no exception for a negated form.
  const besideAVerdict = [
    ...Object.values(VERDICT_LABELS),
    PREINSTALL_SAFETY_CAVEAT,
    SAFETY_SECTION_EXPLAINER,
    CATALOG_LAYOUT_CLEAN,
  ];

  it("never vouches for a package kendex neither wrote nor reviewed", () => {
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
    expect(PREINSTALL_SAFETY_CAVEAT).toBe(
      "An automated check for risky patterns, not a review. It can miss things, and a large skill is read only in part.",
    );
    expect(SAFETY_SECTION_EXPLAINER).toBe(
      "kendex looks for risky patterns in each package before it installs. It is an automated check rather than a review, it can miss things, and a large skill is read only in part.",
    );
  });

  it("keeps the About tab's clean line about layout, not about content", () => {
    expect(CATALOG_LAYOUT_CLEAN).toBe(
      "Nothing wrong with how this catalog is put together.",
    );
  });
});
