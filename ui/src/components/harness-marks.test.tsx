// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import type { HarnessId } from "@/bindings";
import { HARNESS_NAMES } from "@/lib/labels";
import { mount } from "@/test/dom";
import { HarnessIcon } from "./harness-icon";

// `harness-icon.tsx` colours a mark with `text-harness-<id>`, which reaches
// the drawing only where the file hands its paint to the caller. Copilot
// shipped with no fill at all, so both its paths took SVG's default black
// and ignored the token (KEN-930). SOURCES.md re-pulls these marks from
// vendor brand kits and edits their fills by hand, which is how that
// arrives, so the check resolves the paint that reaches each drawn shape
// rather than reading whichever element happens to carry a fill.
const SHAPES = "path, circle, ellipse, rect, polygon, polyline, line";
// Geometry under these draws nothing itself; it defines a mask, a clip or a
// paint server, where a fill is a channel value rather than a colour. They
// are names rather than a selector so that one walk up the ancestors both
// resolves the fill and spots them.
const NON_RENDERING = new Set(["defs", "mask", "clipPath", "symbol"]);

const DEFAULT_BLACK = "(SVG's default black)";

const SOURCES = import.meta.glob("../assets/tools/*.svg", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

const MARKS = Object.entries(SOURCES)
  .map(([path, svg]) => [path.split("/").pop() as string, svg] as const)
  .sort(([a], [b]) => a.localeCompare(b));

const HARNESSES = Object.keys(HARNESS_NAMES) as HarnessId[];

type Painted = { name: string; fill: string };

/** The fill that reaches a drawn shape, or null when the shape draws
 *  nothing at all.
 *
 *  `fill` is an inherited presentation attribute: a shape with none of its
 *  own takes the nearest ancestor's, and one with no ancestor fill either
 *  takes SVG's default, black. */
function fillReaching(shape: Element): string | null {
  let fill = shape.getAttribute("fill");
  for (let above = shape.parentElement; above; above = above.parentElement) {
    if (NON_RENDERING.has(above.localName)) return null;
    fill ??= above.getAttribute("fill");
  }
  return fill ?? DEFAULT_BLACK;
}

/** Every drawn shape under `root`, with the fill that reaches it. Works on a
 *  parsed asset and on a mounted icon alike, so both sites resolve paint the
 *  same way. */
function painted(root: ParentNode): Painted[] {
  const shapes: Painted[] = [];
  for (const shape of root.querySelectorAll(SHAPES)) {
    const fill = fillReaching(shape);
    if (fill === null) continue;
    shapes.push({
      name: shape.getAttribute("d")?.slice(0, 24) ?? shape.tagName,
      fill,
    });
  }
  return shapes;
}

// What a `url(#…)` fill may legitimately name. `localName` again, because
// two of the three are capitalised.
const PAINT_SERVERS = new Set(["linearGradient", "radialGradient", "pattern"]);

/** Whether a `url(#…)` fill reaches a paint server the file actually
 *  carries. A reference resolving to nothing paints nothing, the same blank
 *  mark this file exists to catch, so the id is looked up rather than the
 *  `url(#` prefix matched. */
function paintServer(fill: string, doc: Document): boolean {
  const id = /^url\(#(.+)\)$/.exec(fill)?.[1];
  const named = id ? doc.getElementById(id) : null;
  return named !== null && PAINT_SERVERS.has(named.localName);
}

/** `currentColor` is the token the icon sets; a resolved paint server is the
 *  file's own (Gemini's gradient). A colour literal, the implicit black
 *  default, and an inherited `none` all ignore the token — `none` included,
 *  because every mark here draws with its fill, so a shape that paints none
 *  of it draws nothing. A stroke-drawn mark would red here, and widening
 *  this is the deliberate change that should take. */
const fromTheCaller = ({ fill }: Painted, doc: Document): boolean =>
  fill === "currentColor" || paintServer(fill, doc);

const ignoringTheToken = (shapes: Painted[], doc: Document): string[] =>
  shapes
    .filter((shape) => !fromTheCaller(shape, doc))
    .map((s) => `${s.name} → ${s.fill}`);

function parse(file: string, svg: string): Document {
  const doc = new DOMParser().parseFromString(svg, "image/svg+xml");
  if (doc.querySelector("parsererror")) {
    throw new Error(`${file} is not parseable as SVG`);
  }
  return doc;
}

describe("harness marks", () => {
  it("has one mark file per harness, and no orphans", () => {
    expect(MARKS.map(([file]) => file)).toEqual(
      HARNESSES.map((id) => `${id}.svg`).sort(),
    );
  });

  it.each(MARKS)(
    "%s paints every drawn shape in the caller's colour",
    (file, svg) => {
      const doc = parse(file, svg);
      const shapes = painted(doc);
      // Zero shapes would make the assertion below pass against nothing.
      expect(shapes.length).toBeGreaterThan(0);
      expect(ignoringTheToken(shapes, doc)).toEqual([]);
    },
  );

  it.each(HARNESSES)(
    "%s keeps its paint through the icon svgr builds",
    (id) => {
      const host = mount(<HarnessIcon harness={id} />);
      const mark = host.querySelector("svg") as SVGElement;
      const shapes = painted(mark);
      expect(shapes.length).toBeGreaterThan(0);
      expect(ignoringTheToken(shapes, mark.ownerDocument)).toEqual([]);
      expect(mark.getAttribute("class")).toContain(`text-harness-${id}`);
    },
  );
});
