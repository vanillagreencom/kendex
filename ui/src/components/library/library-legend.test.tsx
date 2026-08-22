import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { AS_INSTALLED_LEGEND } from "@/lib/copy-customize";
import { LibraryLegend } from "./library-legend";

// The key to a colour is read as a claim about every row carrying it, and a
// muted icon covers both "nothing of yours here" and "nothing could be read
// here" — so it promises only what was actually found.
describe("the Library's colour key", () => {
  it("says what was found, not that every place was checked", () => {
    const html = renderToStaticMarkup(<LibraryLegend />);
    expect(html).toContain(AS_INSTALLED_LEGEND);
    expect(html).not.toContain("As the author wrote it");
  });

  it("leaves where to the row rather than claiming it here", () => {
    expect(renderToStaticMarkup(<LibraryLegend />)).toContain(
      "the row names where",
    );
  });
});
