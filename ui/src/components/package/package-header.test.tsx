import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { PlaceMark } from "@/lib/place-marks";
import { PackageHeader } from "./package-header";

// The mark has to reach the screen as words: a helper that returns the
// right label proves nothing if the header renders something else.
describe("PackageHeader", () => {
  const render = (mark: PlaceMark | null) =>
    renderToStaticMarkup(
      <PackageHeader
        kind="skill"
        displayName="gh"
        description="about gh"
        forked={false}
        forkEdited={false}
        mark={mark}
        requiredBy={[]}
        action={null}
      />,
    );

  const mark: PlaceMark = {
    label: "Customized in vg · 1 of 3 places",
    goTo: null,
    why: "settings",
  };

  it("renders the mark and icon for customized and unchanged packages", () => {
    const rows = [
      {
        name: "customized",
        value: mark,
        color: "text-customized",
        text: "Customized in vg · 1 of 3 places",
      },
      {
        name: "unchanged",
        value: null,
        color: "text-muted-foreground",
        text: null,
      },
    ];
    expect(rows).toHaveLength(2);
    for (const entry of rows) {
      const shown = render(entry.value);
      expect(shown, entry.name).toContain(
        `translate-y-[0.1875rem] ${entry.color}`,
      );
      if (entry.text !== null) {
        expect(shown).toContain(entry.text);
        expect(shown).not.toContain("badge");
      } else {
        expect(shown).not.toContain("Customized");
        expect(shown).not.toContain("text-customized");
      }
    }
  });
});
