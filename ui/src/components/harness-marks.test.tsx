// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import { HARNESS_NAMES } from "@/lib/labels";
import { mount } from "@/test/dom";
import { HarnessIcon } from "./harness-icon";

// `harness-icon.tsx` colours a mark with `text-harness-<id>`, which reaches
// the drawing only where the file hands its paint to the caller. Copilot
// shipped with no fill at all, so both its paths took SVG's default black
// and ignored the token (KEN-930). SOURCES.md re-pulls these marks from
// vendor brand kits and edits their fills by hand, which is how that
// arrives, so the check is per drawn shape and on the value, not on whether
// some ancestor happens to name a fill.
const SHAPES = "path, circle, ellipse, rect, polygon, polyline, line";
// Geometry under these draws nothing itself; it defines a mask, a clip or a
// paint server, where a fill is a channel value rather than a colour.
const NON_RENDERING = "defs, mask, clipPath, symbol";

const SOURCES = import.meta.glob("../assets/tools/*.svg", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

const MARKS = Object.entries(SOURCES)
  .map(([path, svg]) => [path.split("/").pop() as string, svg] as const)
  .sort(([a], [b]) => a.localeCompare(b));

const EXPECTED = Object.keys(HARNESS_NAMES)
  .map((id) => `${id}.svg`)
  .sort();

/** The fill each drawn shape is painted with, as `<geometry> → <fill>`.
 *
 *  `fill` is an inherited presentation attribute: a shape with none of its
 *  own takes the nearest ancestor's, and one with no ancestor fill either
 *  takes SVG's default, black. */
function fills(file: string, svg: string): string[] {
  const doc = new DOMParser().parseFromString(svg, "image/svg+xml");
  if (doc.querySelector("parsererror")) {
    throw new Error(`${file} is not parseable as SVG`);
  }
  const painted: string[] = [];
  for (const shape of doc.querySelectorAll(SHAPES)) {
    if (shape.closest(NON_RENDERING)) continue;
    let source: Element | null = shape;
    while (source && !source.hasAttribute("fill")) {
      source = source.parentElement;
    }
    const name = shape.getAttribute("d")?.slice(0, 24) ?? shape.tagName;
    painted.push(
      `${name} → ${source?.getAttribute("fill") ?? "(default black)"}`,
    );
  }
  return painted;
}

/** `currentColor` is the token the icon sets; `url(#…)` is a paint server
 *  the file carries (Gemini's gradient). A colour literal, the implicit
 *  black default, and an inherited `none` all ignore the token — `none`
 *  included, because every mark here draws with its fill, so a shape that
 *  paints none of it draws nothing. A stroke-drawn mark would red here, and
 *  widening this is the deliberate change that should take. */
const fromTheCaller = (line: string): boolean => {
  const fill = line.split(" → ")[1];
  return fill === "currentColor" || fill.startsWith("url(#");
};

describe("harness marks", () => {
  it("has one mark file per harness, and no orphans", () => {
    expect(MARKS.map(([file]) => file)).toEqual(EXPECTED);
  });

  it.each(MARKS)(
    "%s paints every drawn shape in the caller's colour",
    (file, svg) => {
      const painted = fills(file, svg);
      // Zero shapes would make the assertion below pass against nothing.
      expect(painted.length).toBeGreaterThan(0);
      expect(painted.filter((line) => !fromTheCaller(line))).toEqual([]);
    },
  );

  it("hands Copilot's fill to the icon svgr builds", () => {
    const mark = mount(<HarnessIcon harness="copilot" />).querySelector("svg");
    expect(mark?.getAttribute("fill")).toBe("currentColor");
    expect(mark?.getAttribute("class")).toContain("text-harness-copilot");
  });
});
