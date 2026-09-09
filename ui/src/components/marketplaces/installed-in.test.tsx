// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Scope } from "@/bindings";
import { useNavStore } from "@/stores/nav";
import { mount, settle } from "@/test/dom";
import { InstalledIn } from "./installed-in";

const project = (root: string): Scope => ({ scope: "project", root });
const PERSONAL: Scope = { scope: "global" };

const goToLibrary = vi.fn();

beforeEach(() => {
  goToLibrary.mockReset();
  useNavStore.setState({ goToLibrary });
});

const drawn = (places: Scope[], standalone = true) => {
  const host = mount(<InstalledIn places={places} standalone={standalone} />);
  const trigger = host.querySelector("button");
  return {
    host,
    said: trigger?.textContent ?? "",
    announced: trigger?.getAttribute("aria-label") ?? "",
  };
};

// This is the one control a marketplace page leaves to say where its
// packages landed, so its count has to name the kind of place the menu
// behind it actually lists. The personal setup is a place and not a
// project, which the app says in copy-model.ts and counts by in
// place-word.ts.
describe("the control that says where a package is installed", () => {
  it("counts personal-only, project-only and mixed installs by what they hold", () => {
    const rows = [
      {
        name: "the personal setup alone",
        places: [PERSONAL],
        said: "Installed in 1 place",
      },
      {
        name: "one project alone",
        places: [project("/w/alpha")],
        said: "Installed in 1 project",
      },
      {
        name: "two projects",
        places: [project("/w/alpha"), project("/w/beta")],
        said: "Installed in 2 projects",
      },
      {
        name: "the personal setup and a project",
        places: [PERSONAL, project("/w/alpha")],
        said: "Installed in 2 places",
      },
    ];
    expect(rows).toHaveLength(4);
    for (const row of rows) {
      const control = drawn(row.places);
      expect(control.said, row.name).toBe(row.said);
      // What a screen reader hears is the whole phrase either way: it has
      // not read the column head standing beside a table cell.
      expect(control.announced, row.name).toBe(row.said);
    }
  });

  // A table column heads its cells with the verb once, so the cell carries
  // only the count — the same count, by the same rule.
  it("drops the verb in a column that already carries it", () => {
    const control = drawn([PERSONAL, project("/w/alpha")], false);
    expect(control.said).toBe("2 places");
    expect(control.announced).toBe("Installed in 2 places");
  });

  // The count says a kind of place; the menu names each one. Personal is
  // named Personal, and it is reachable.
  it("names every place it counted and opens the one that is picked", async () => {
    const control = drawn([PERSONAL, project("/w/alpha")]);
    // A base-ui menu trigger does not open on a click under jsdom; focus it
    // and press Enter, as `@/test/dom` says. The popup is portalled and
    // mounts a tick after the state that opens it, so one drained microtask
    // queue is not enough.
    act(() => (control.host.querySelector("button") as HTMLElement).focus());
    await userEvent.keyboard("{Enter}");
    await settle();
    await settle();

    const items = [
      ...document.querySelectorAll('[role="menuitem"]'),
    ] as HTMLElement[];
    expect(items.map((item) => item.textContent)).toEqual([
      "Personal",
      "alpha",
    ]);

    await userEvent.click(items[0]);
    expect(goToLibrary).toHaveBeenCalledWith({ scope: "global" });
  });
});
