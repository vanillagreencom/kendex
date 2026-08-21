import { describe, expect, it } from "vitest";
import {
  publisherSettledLabel,
  publisherSettledNote,
  settledSummaryLead,
} from "./copy-safety";

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
