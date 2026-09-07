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

  it("prints what the mark says about the package", () => {
    expect(render(mark)).toContain("Customized in vg · 1 of 3 places");
  });

  it("says nothing where no place holds anything", () => {
    expect(render(null)).not.toContain("Customized");
  });

  // The header is the one place that says a package is customized: the
  // kind icon takes the colour and the words sit under the name, not in
  // a pill of their own.
  it("marks it with the icon colour and the words, not with a badge", () => {
    const shown = render(mark);
    // The kind icon takes the customized colour.
    expect(shown).toContain("translate-y-[0.1875rem] text-customized");
    // And the words are plain text, not a pill.
    expect(shown).not.toContain("badge");
  });

  it("leaves the icon muted where nothing is customized", () => {
    const shown = render(null);
    expect(shown).toContain("translate-y-[0.1875rem] text-muted-foreground");
    expect(shown).not.toContain("text-customized");
  });
});
