// @vitest-environment jsdom
import { describe, expect, it } from "vitest";
import type { BundleDetail, Catalog } from "@/bindings";
import { mount } from "@/test/dom";
import { BundleCards } from "./bundle-cards";

const catalog: Catalog = {
  by: "subscription",
  scope: { scope: "global" },
  source: "kit",
};

const set = (name: string, members: number, installed = 0): BundleDetail => ({
  name,
  description: `${name} description`,
  version: null,
  category: null,
  members: Array.from({ length: members }, (_, i) => ({
    kind: "skill" as const,
    name: `${name}-${i}`,
    state: i < installed ? ("installed" as const) : ("available" as const),
  })),
  installedMembers: installed,
  totalMembers: members,
  collision: null,
});

const text = (node: { textContent: string | null }): string =>
  node.textContent ?? "";

describe("the Bundles tab", () => {
  // The bug: a pending read looked the same as a catalog with no sets, so
  // the tab said the marketplace offers none while its read was still out.
  it("says it is reading while the read is pending, never that there are none", () => {
    const host = mount(
      <BundleCards catalog={catalog} bundles={undefined} error={undefined} />,
    );
    expect(text(host)).toContain("Reading its curated sets");
    expect(text(host)).not.toContain("doesn't offer curated sets");
  });

  it("shows the read error rather than an empty tab", () => {
    const host = mount(
      <BundleCards
        catalog={catalog}
        bundles={undefined}
        error="fetch refused"
      />,
    );
    expect(host.querySelector('[role="alert"]')).not.toBeNull();
    expect(text(host)).toContain("fetch refused");
    expect(text(host)).not.toContain("doesn't offer curated sets");
  });

  it("says the marketplace offers none only for a read that landed empty", () => {
    const host = mount(
      <BundleCards catalog={catalog} bundles={[]} error={undefined} />,
    );
    expect(text(host)).toContain("doesn't offer curated sets");
  });

  // The badge is the only thing on a card that says how much of a set is
  // already here, and it has three answers, not one.
  it("badges a set by how much of it is installed", () => {
    const host = mount(
      <BundleCards
        catalog={catalog}
        bundles={[set("whole", 3, 3), set("some", 3, 1), set("none", 3, 0)]}
        error={undefined}
      />,
    );
    const badges = [...host.querySelectorAll("button")].map(
      (button) =>
        button.parentElement?.querySelector("span")?.textContent ?? "",
    );
    expect(badges).toEqual(["Installed", "Partly installed (1 of 3)", ""]);
  });

  it("cards every declared set with its description and member counts", () => {
    const host = mount(
      <BundleCards
        catalog={catalog}
        bundles={[set("starter", 2), set("orphaned", 1)]}
        error={undefined}
      />,
    );
    const cards = [...host.querySelectorAll("button")].map((button) =>
      text(button.closest("div.flex.h-full") ?? button),
    );
    expect(cards).toHaveLength(2);
    expect(cards[0]).toContain("starter");
    expect(cards[0]).toContain("starter description");
    expect(cards[0]).toContain("2 skills");
    expect(cards[1]).toContain("orphaned");
    expect(cards[1]).toContain("1 skill");
  });
});
