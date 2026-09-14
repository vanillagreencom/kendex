// @vitest-environment jsdom
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { UnreadablePlacesNote } from "./updates-unreadable-note";

// A place with no update standing is a Problem, so its note is red like
// its row on Home.
describe("the note for places with no update standing", () => {
  it("wears the Problem tone", () => {
    const html = renderToStaticMarkup(
      <UnreadablePlacesNote
        places={[{ scope: { scope: "global" }, message: "lock unreadable" }]}
      />,
    );
    expect(html).toContain("border-critical/30");
  });
});
