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
        mark={mark}
        action={null}
      />,
    );

  it("prints the place the mark names", () => {
    const shown = render({
      label: "Customized in vg",
      goTo: { scope: "project", root: "/work/vg" },
      why: "settings",
    });
    expect(shown).toContain("Customized in vg");
  });

  it("says nothing where this place holds nothing", () => {
    expect(render(null)).not.toContain("Customized");
  });
});
