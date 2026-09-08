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
  recordsUnreadable: false,
});

const text = (node: { textContent: string | null }): string =>
  node.textContent ?? "";

describe("the Bundles tab", () => {
  it("distinguishes pending, failed and landed-empty bundle reads", () => {
    const rows: {
      name: string;
      bundles: BundleDetail[] | undefined;
      error: string | undefined;
      shown: string;
      absent: string | null;
      alert: boolean;
    }[] = [
      {
        name: "pending",
        bundles: undefined,
        error: undefined,
        shown: "Reading its curated sets",
        absent: "doesn't offer curated sets",
        alert: false,
      },
      {
        name: "failed",
        bundles: undefined,
        error: "fetch refused",
        shown: "fetch refused",
        absent: "doesn't offer curated sets",
        alert: true,
      },
      {
        name: "landed empty",
        bundles: [],
        error: undefined,
        shown: "doesn't offer curated sets",
        absent: null,
        alert: false,
      },
    ];
    expect(rows).toHaveLength(3);
    for (const row of rows) {
      const host = mount(
        <BundleCards
          catalog={catalog}
          bundles={row.bundles}
          error={row.error}
        />,
      );
      expect(text(host), row.name).toContain(row.shown);
      if (row.absent !== null)
        expect(text(host), row.name).not.toContain(row.absent);
      if (row.alert)
        expect(host.querySelector('[role="alert"]')).not.toBeNull();
    }
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
