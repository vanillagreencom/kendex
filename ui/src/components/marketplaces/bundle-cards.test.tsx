// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
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
  it("names the places a set is installed in without opening the set", async () => {
    const members: Scope[] = [
      { scope: "global" },
      { scope: "project", root: "/w/alpha" },
    ];
    const host = mount(
      <BundleCards
        catalog={catalog}
        bundles={[set("starter", 2)]}
        error={undefined}
        places={
          new Map([
            [placesKey("skill", "starter-0"), [members[0]]],
            [placesKey("skill", "starter-1"), [members[1]]],
          ])
        }
      />,
    );
    const control = host.querySelector(
      `button[aria-label="${installedInLabel(members)}"]`,
    ) as HTMLElement;
    expect(control.textContent).toBe(installedInLabel(members));

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

// The card is the way into the set it names, so it carries no Open button
// of its own — and the keyboard takes the same way in.
describe("opening a curated set", () => {
  const cards = () =>
    mount(
      <BundleCards
        catalog={catalog}
        bundles={[set("starter", 3, 0)]}
        error={undefined}
        places={new Map()}
      />,
    );

  it("opens from the card by pointer and by Enter, with no Open button", async () => {
    const methods = ["pointer", "keyboard"] as const;
    expect(methods).toHaveLength(2);
    for (const method of methods) {
      goToBundle.mockReset();
      const host = cards();
      expect(host.textContent).not.toContain("Open");
      const card = host.querySelector<HTMLElement>('[data-slot="card"]');
      if (!card) throw new Error("no card rendered");
      expect(card.getAttribute("tabindex")).toBe("0");
      if (method === "pointer") await userEvent.click(card);
      else {
        act(() => card.focus());
        await userEvent.keyboard("{Enter}");
      }
      expect(goToBundle, method).toHaveBeenCalledWith({
        catalog,
        bundle: "starter",
      });
    }
  });

  // The control: the name is a real control of its own, so a screen reader
  // is told what opens rather than being handed a card only a click acts on.
  it("names the set on a control, not only in the card's text", async () => {
    const host = cards();
    const name = [...host.querySelectorAll("button")].find(
      (button) => button.textContent === "starter",
    );
    if (!name) throw new Error("the set's name is not a button");
    await userEvent.click(name);
    expect(goToBundle).toHaveBeenCalledWith({ catalog, bundle: "starter" });
  });
});
