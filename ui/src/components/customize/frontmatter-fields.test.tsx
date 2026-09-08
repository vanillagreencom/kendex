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
  it("marks values while leaving placeholder examples unmarked", () => {
    const rows: {
      name: string;
      overrides: Partial<DraftFrontmatter>;
      marked: boolean;
      color?: boolean;
    }[] = [
      {
        name: "text value beside an unset model example",
        overrides: { effort: "xhigh" },
        marked: true,
        color: true,
      },
      { name: "only examples", overrides: {}, marked: false, color: false },
      {
        name: "list value",
        overrides: { "allow-tools": ["Read"] },
        marked: true,
      },
      { name: "flag value", overrides: { pane: true }, marked: true },
    ];
    expect(rows).toHaveLength(4);
    for (const { name, overrides, marked, color } of rows) {
      const shown = render(overrides);
      expect(shown.includes(CUSTOMIZED_MARK), name).toBe(marked);
      if (color !== undefined)
        expect(shown.includes("text-customized"), name).toBe(color);
      if (name === "text value beside an unset model example") {
        expect(shown).toContain('placeholder="opus"');
        expect(shown.match(/text-customized/g)).toHaveLength(1);
      }
    }
  });
});
