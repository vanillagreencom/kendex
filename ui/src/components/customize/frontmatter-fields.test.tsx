import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { FrontmatterFields } from "@/components/customize/frontmatter-fields";
import { CUSTOMIZED_MARK } from "@/lib/copy-customize";
import type { DraftFrontmatter } from "@/lib/editor-draft";

const render = (overrides: Partial<DraftFrontmatter>) =>
  renderToStaticMarkup(
    <FrontmatterFields
      overrides={overrides as DraftFrontmatter}
      onSet={() => {}}
    />,
  );

// Every box in this grid carries a placeholder example. Read as values,
// they make a place customized only through Settings look untouched, and
// the manifest holding the customization look unloaded.
describe("a field holding a value of the reader's", () => {
  it("says so on its label, in words as well as in colour", () => {
    const shown = render({ effort: "xhigh" });
    expect(shown).toContain("text-customized");
    expect(shown).toContain(CUSTOMIZED_MARK);
  });

  it("marks nothing where the grid is all examples", () => {
    const shown = render({});
    expect(shown).not.toContain("text-customized");
    expect(shown).not.toContain(CUSTOMIZED_MARK);
  });

  // A placeholder is still on screen for an unset field; the mark is what
  // tells the two apart, so it must not follow the placeholder.
  it("leaves a field showing only its example unmarked", () => {
    const shown = render({ effort: "xhigh" });
    expect(shown).toContain('placeholder="opus"');
    expect(shown.match(/text-customized/g)).toHaveLength(1);
  });

  it("marks a list and a flag the same way it marks text", () => {
    expect(render({ "allow-tools": ["Read"] })).toContain(CUSTOMIZED_MARK);
    expect(render({ pane: true })).toContain(CUSTOMIZED_MARK);
  });
});
