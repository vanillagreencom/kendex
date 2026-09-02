// @vitest-environment jsdom
import { describe, expect, it } from "vitest";

// `harness-icon.tsx` colours a mark with `text-harness-<id>`, which only
// reaches the drawing if the file says where its fill comes from. A shape
// with no fill anywhere above it takes SVG's default — black — and ignores
// the token. Copilot shipped that way (KEN-930).
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

/** Shapes that would be painted with SVG's default black, named by the start
 *  of their geometry. */
function unfilled(svg: string): string[] {
  const doc = new DOMParser().parseFromString(svg, "image/svg+xml");
  const missing: string[] = [];
  for (const shape of doc.querySelectorAll(SHAPES)) {
    if (shape.closest(NON_RENDERING)) continue;
    let source: Element | null = shape;
    while (source && !source.hasAttribute("fill")) {
      source = source.parentElement;
    }
    if (!source) {
      missing.push(shape.getAttribute("d")?.slice(0, 24) ?? shape.tagName);
    }
  }
  return missing;
}

describe("harness marks", () => {
  it("covers every mark the icon can draw", () => {
    expect(MARKS.map(([file]) => file)).toEqual([
      "claude.svg",
      "codex.svg",
      "copilot.svg",
      "cursor.svg",
      "gemini.svg",
      "opencode.svg",
      "pi.svg",
    ]);
  });

  it.each(MARKS)(
    "%s says where every drawn shape's fill comes from",
    (_file, svg) => {
      expect(unfilled(svg)).toEqual([]);
    },
  );
});
