import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { PackagePlace } from "@/lib/package-places";
import { ProjectCard } from "./project-card";

const place: PackagePlace = {
  scope: { scope: "project", root: "/home/me/app" },
  name: "app",
  // A lock's own string, which nobody validated on the way in.
  installedAt: "not a date",
  row: null,
  updatable: false,
  removable: false,
};

// The card renders the path whether or not the date reads, so an
// unreadable one reaches the title. Formatting it used to throw, which
// took the whole Projects tab with it rather than dropping one attribute.
describe("a place whose install date cannot be read", () => {
  it("renders the card without a title rather than throwing", () => {
    const html = renderToStaticMarkup(
      <ProjectCard
        place={place}
        busy={false}
        removalHeld={false}
        onUpdate={() => {}}
        onRemove={() => {}}
      />,
    );
    expect(html).toContain("/home/me/app");
    expect(html).not.toContain("title=");
  });
});
