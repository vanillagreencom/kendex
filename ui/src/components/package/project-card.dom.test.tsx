// @vitest-environment jsdom
import { describe, expect, it, vi } from "vitest";
import type { PackagePlace } from "@/lib/package-places";
import { mount } from "@/test/dom";
import { ProjectCard } from "./project-card";

const place: PackagePlace = {
  scope: { scope: "project", root: "/work/vg" },
  name: "vg",
  installedAt: null,
  row: null,
  updatable: false,
  removable: false,
};

const draw = (focused: boolean) =>
  mount(
    <ProjectCard
      place={place}
      busy={false}
      removalHeld={false}
      focused={focused}
      setup={null}
      onOpen={() => {}}
      onUpdate={() => {}}
      onRemove={() => {}}
      onSetUp={() => {}}
      onCheckAgain={() => {}}
    />,
  );

/** The Overview's setup line names a project and says "Show me". Landing
 *  on the tab is not landing on the row, so the card it named brings
 *  itself into view — which needs the ref to reach a real element. */
describe("the card the reader was sent to", () => {
  it("brings itself into view, and only when it was named", () => {
    const scrolled = vi.fn();
    Element.prototype.scrollIntoView = scrolled;

    draw(false);
    expect(scrolled).not.toHaveBeenCalled();

    draw(true);
    expect(scrolled).toHaveBeenCalledTimes(1);
  });
});
