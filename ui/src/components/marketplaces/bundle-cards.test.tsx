// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { BundleDetail, Catalog, Scope } from "@/bindings";
import { installedInLabel } from "@/lib/copy-marketplaces";
import { placesKey } from "@/lib/installed-places";
import { useNavStore } from "@/stores/nav";
import { mount } from "@/test/dom";
import { BundleCards } from "./bundle-cards";

const goToBundle = vi.fn();

beforeEach(() => {
  goToBundle.mockReset();
  useNavStore.setState({ goToBundle });
});

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
          places={new Map()}
        />,
      );
      expect(text(host), row.name).toContain(row.shown);
      if (row.absent !== null)
        expect(text(host), row.name).not.toContain(row.absent);
      if (row.alert)
        expect(host.querySelector('[role="alert"]')).not.toBeNull();
    }
  });

  // The state line is the only thing on a card that says how much of a set
  // is already here, and it has three answers, not one.
  it("says how much of a set is installed", () => {
    const host = mount(
      <BundleCards
        catalog={catalog}
        bundles={[set("whole", 3, 3), set("some", 3, 1), set("none", 3, 0)]}
        error={undefined}
        places={new Map()}
      />,
    );
    const said = [...host.querySelectorAll('[data-slot="card"]')].map(
      (card) => card.querySelector("span.truncate")?.textContent ?? "",
    );
    expect(said).toEqual(["Installed", "Partly installed (1 of 3)", ""]);
  });

  it("cards every declared set with its description and member counts", () => {
    const host = mount(
      <BundleCards
        catalog={catalog}
        bundles={[set("starter", 2), set("orphaned", 1)]}
        error={undefined}
        places={new Map()}
      />,
    );
    const cards = [...host.querySelectorAll('[data-slot="card"]')].map(text);
    expect(cards).toHaveLength(2);
    expect(cards[0]).toContain("starter");
    expect(cards[0]).toContain("starter description");
    expect(cards[0]).toContain("2 skills");
    expect(cards[1]).toContain("orphaned");
    expect(cards[1]).toContain("1 skill");
  });

  // The card is the open action: its own empty space opens the set, and no
  // Open button stands beside a name that already does it. The name keeps a
  // button of its own so the keyboard reaches the set too.
  it("opens the set from the card and from its name, with no Open button", async () => {
    const host = mount(
      <BundleCards
        catalog={catalog}
        bundles={[set("starter", 2)]}
        error={undefined}
        places={new Map()}
      />,
    );
    const card = host.querySelector('[data-slot="card"]') as HTMLElement;
    expect(text(card)).not.toContain("Open");

    await userEvent.click(card.querySelector("button") as HTMLElement);
    await userEvent.click(card);

    expect(goToBundle.mock.calls).toEqual([
      [{ catalog, bundle: "starter" }],
      [{ catalog, bundle: "starter" }],
    ]);
  });

  // Which projects hold a set is a fact about the set, said on the card and
  // opened from it — and the control that opens them must not open the set
  // underneath it.
  it("names the projects a set is installed in without opening the set", async () => {
    const host = mount(
      <BundleCards
        catalog={catalog}
        bundles={[set("starter", 2)]}
        error={undefined}
        places={
          new Map([
            [placesKey("skill", "starter-0"), [{ scope: "global" } as Scope]],
            [
              placesKey("skill", "starter-1"),
              [{ scope: "project", root: "/w/alpha" } as Scope],
            ],
          ])
        }
      />,
    );
    const control = host.querySelector(
      `button[aria-label="${installedInLabel(2)}"]`,
    ) as HTMLElement;
    expect(control.textContent).toBe(installedInLabel(2));

    await userEvent.click(control);
    expect(goToBundle).not.toHaveBeenCalled();
  });

  it("says nothing about projects for a set installed in none", () => {
    const host = mount(
      <BundleCards
        catalog={catalog}
        bundles={[set("starter", 2)]}
        error={undefined}
        places={new Map()}
      />,
    );
    expect(text(host)).not.toContain("Installed in");
  });
});
