import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { PlaceMark } from "@/lib/place-marks";
import { PackageHeader } from "./package-header";

// The mark has to reach the screen as words: a helper that returns the
// right label proves nothing if the header renders something else.
describe("PackageHeader", () => {
  const render = (mark: PlaceMark | null, requiredBy: string[] = []) =>
    renderToStaticMarkup(
      <PackageHeader
        kind="skill"
        displayName="gh"
        description="about gh"
        forked={false}
        mark={mark}
        requiredBy={requiredBy}
        action={null}
      />,
    );

  const mark: PlaceMark = {
    label: "Customized in vg · 1 of 3 places",
    goTo: null,
    why: "settings",
  };

  it("prints what the mark says about the package", () => {
    expect(render(mark)).toContain("Customized in vg · 1 of 3 places");
  });

  it("says nothing where no place holds anything", () => {
    expect(render(null)).not.toContain("Customized");
  });

  // The Library row marks a customized package by colouring its kind icon
  // and putting the mark under the name in that colour. The header says
  // the same thing the same way rather than in a pill of its own.
  it("marks it the way the Library row does, not with a badge", () => {
    const shown = render(mark);
    // The kind icon takes the customized colour, as it does on the row.
    expect(shown).toContain("translate-y-[0.1875rem] text-customized");
    // And the words are plain text, not the pill this header used to draw.
    expect(shown).not.toContain("badge");
  });

  // Why this package is here at all, for one nobody asked for by name.
  it("says which package required this one", () => {
    expect(render(null, ["dev"])).toContain(
      "Installed because dev requires it.",
    );
  });

  it("names every package that requires it", () => {
    expect(render(null, ["dev", "orch"])).toContain(
      "Installed because dev and orch require it.",
    );
  });

  it("says nothing where nothing requires it", () => {
    expect(render(null, [])).not.toContain("Installed because");
  });

  it("leaves the icon muted where nothing is customized", () => {
    const shown = render(null);
    expect(shown).toContain("translate-y-[0.1875rem] text-muted-foreground");
    expect(shown).not.toContain("text-customized");
  });
});
