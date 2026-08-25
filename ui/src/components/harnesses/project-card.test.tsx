import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { ProjectCard } from "./project-card";

const render = (over: { unmanaged?: number } = {}) =>
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
});
