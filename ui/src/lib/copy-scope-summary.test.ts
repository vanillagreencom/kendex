import { describe, expect, it } from "vitest";
import { scopeSummaryLabel } from "@/lib/copy";

const none = { changes: 0, conflicts: 0, blocked: 0, open: 0, unmanaged: 0 };

// The collapsed card is all a reader sees until they open it, so it has to
// account for everything the card contains.
describe("what a collapsed scope card says it has", () => {
  it("says nothing only when there is nothing", () => {
    expect(scopeSummaryLabel(none)).toBe(null);
  });

  it("counts a conflict, which no apply can clear", () => {
    // An edited fork is the ordinary case: its only exit is on the
    // package's own page, so it is never "to apply" — but a card that
    // omits it reads as clean and opens onto a section saying otherwise.
    expect(scopeSummaryLabel({ ...none, conflicts: 1 })).toBe(
      "1 waiting on you",
    );
    expect(scopeSummaryLabel({ ...none, conflicts: 2, changes: 1 })).toBe(
      "2 waiting on you · 1 to apply",
    );
  });
});
