import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { PLACE_UNCHECKED_LABEL } from "@/lib/copy";
import { ProjectCard } from "./project-card";

// Static markup escapes apostrophes, so copy carrying one is escaped the
// same way before it is looked for.
const esc = (copy: string) => copy.replace(/'/g, "&#x27;");

const render = (over: { unmanaged?: number | null } = {}) =>
  renderToStaticMarkup(
    <ProjectCard
      name="acme"
      subtitle="/work/acme"
      counts={[["skill", 3]]}
      emptyLabel="Nothing from kendex yet."
      onOpen={() => {}}
      onKindClick={() => {}}
      onUnmanaged={() => {}}
      {...over}
    />,
  );

describe("a place's card", () => {
  it("counts what kendex is not looking after, beside what it is", () => {
    const html = render({ unmanaged: 4 });
    expect(html).toContain("3 Skills");
    expect(html).toContain("4 not managed yet");
  });

  // This is the app's only mention of unmanaged content, and nothing about
  // it is wrong — a card saying "0 not managed" on every project would be
  // a nag on a page that is about what is installed.
  it("says nothing when there is nothing unmanaged", () => {
    expect(render({ unmanaged: 0 })).not.toContain("not managed");
    expect(render()).not.toContain("not managed");
  });

  // A place the audit could not read holds an unknown number, not zero.
  // Saying nothing would read as nothing unmanaged; offering the link would
  // open a list of rows nothing has confirmed still exist, each with a
  // button that writes to the filesystem.
  it("says the place could not be checked instead of counting it", () => {
    const html = render({ unmanaged: null });
    expect(html).toContain(esc(PLACE_UNCHECKED_LABEL));
    expect(html).not.toContain("not managed yet");
    // The kind counts come from the scan, which still answered.
    expect(html).toContain("3 Skills");
  });

  it("offers nothing to click for a place it could not check", () => {
    const html = render({ unmanaged: null });
    // The card carries other buttons — its name, its kind counts — so what
    // matters is the tag these particular words sit in: the nearest one
    // opened before them is a span, never a button.
    const before = html.slice(0, html.indexOf(esc(PLACE_UNCHECKED_LABEL)));
    expect(before.lastIndexOf("<span")).toBeGreaterThan(
      before.lastIndexOf("<button"),
    );
  });
});
