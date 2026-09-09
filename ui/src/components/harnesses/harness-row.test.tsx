// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  HARNESS_VERSION_HELP,
  harnessRootHelp,
  showKindLabel,
} from "@/lib/copy";
import { harnessName, kindLabel } from "@/lib/labels";
import { showEverythingLabel } from "@/lib/show-everything-label";
import { useNavStore } from "@/stores/nav";
import { mount as mountTree } from "@/test/dom";
import { HarnessRow } from "./harness-row";

// The nav store is the real one — whether a click lands the Library on the
// right view is exactly what these tests ask — so each test starts from a
// page that is not the Library and no pending filter.
const navHome = { page: "home" as const, libraryFilter: null };

afterEach(() => {
  vi.restoreAllMocks();
});

const mount = (detectedRoot: string | null, version: string | null = null) => {
  useNavStore.setState(navHome);
  return mountTree(
    <HarnessRow
      place={{ harness: "claude" }}
      detectedRoot={detectedRoot}
      version={version}
      counts={[["skill", 3]]}
      folder=""
      onFolderChange={() => {}}
    />,
  );
};

const label = showEverythingLabel(harnessName("claude"));

describe("the harness row's name", () => {
  it("opens the Library scoped to this harness, with no kind picked", async () => {
    const host = mount("/home/u/.claude");
    // Queried by accessible name, so the label sitting anywhere but the
    // name button fails here too.
    const name = host.querySelector<HTMLButtonElement>(
      `button[aria-label="${label}"]`,
    );
    if (!name) throw new Error("no show-everything button rendered");
    expect(name.textContent).toBe("Claude Code");
    expect(name.getAttribute("aria-label")).toBe(
      "Show everything in Claude Code",
    );

    await userEvent.click(name);
    const nav = useNavStore.getState();
    expect(nav.page).toBe("library");
    expect(nav.libraryFilter?.harness).toBe("claude");
    expect(nav.libraryFilter?.kind).toBeUndefined();
    expect(nav.libraryFilter?.scope).toBeUndefined();
  });

  it("opens by pointer and keyboard while a selection stands elsewhere", async () => {
    const methods = ["pointer", "keyboard"] as const;
    expect(methods).toHaveLength(2);
    for (const method of methods) {
      const host = mount("/home/u/.claude");
      const name = host.querySelector<HTMLButtonElement>(
        `button[aria-label="${label}"]`,
      );
      if (!name) throw new Error("no show-everything button rendered");
      vi.spyOn(window, "getSelection").mockReturnValue({
        isCollapsed: false,
      } as Selection);
      if (method === "pointer") await userEvent.click(name);
      else {
        name.focus();
        await userEvent.keyboard("{Enter}");
      }
      expect(useNavStore.getState().page, method).toBe("library");
    }
  });

  it("offers nothing to show for a harness that is not installed", () => {
    const host = mount(null);
    expect(host.querySelector(`button[aria-label="${label}"]`)).toBeNull();
    const named = Array.from(host.querySelectorAll("button")).filter(
      (b) => b.textContent === "Claude Code",
    );
    expect(named).toEqual([]);
    expect(useNavStore.getState().page).toBe("home");
  });
});

// Three things on this row are shown without a word saying what they are: a
// path, a version number, and a count badge whose press goes somewhere the
// count does not name. Each says it where a pointer, a keyboard or a screen
// reader can ask.
describe("what a harness row's line and badges say they are", () => {
  it("names the path, the version and where a count badge lands", () => {
    const host = mount("/home/u/.claude", "2.4.0");
    // The leaf that holds the words, not the wrapper around it and the
    // pencil, which carries the same textContent and a title of its own.
    const leaf = (text: string) =>
      [...host.querySelectorAll<HTMLElement>("span")].find(
        (el) => el.children.length === 0 && el.textContent === text,
      );
    const path = leaf("/home/u/.claude");
    expect(path?.title).toBe(harnessRootHelp("Claude Code"));
    const version = leaf("2.4.0");
    expect(version?.title).toBe(HARNESS_VERSION_HELP);
    const badge = [...host.querySelectorAll<HTMLButtonElement>("button")].find(
      (b) => b.textContent === `3 ${kindLabel("skill", 3)}`,
    );
    expect(badge?.getAttribute("aria-label")).toBe(
      showKindLabel(3, kindLabel("skill", 3), "Claude Code"),
    );
  });

  // The must-fail half: a row that pinned one sentence to every line would
  // pass the case above and call a missing harness's "Not installed" the
  // place its files are kept.
  it("claims no folder for a harness that has none", () => {
    const host = mount(null);
    const line = [...host.querySelectorAll<HTMLElement>("span")].find(
      (el) => el.children.length === 0 && el.textContent === "Not installed",
    );
    if (!line) throw new Error("no not-installed line");
    expect(line.title).toBe("");
  });
});

// The row reads as one target, so the whole of it opens the harness — the
// same view its name opens.
describe("the harness row itself", () => {
  it("opens the harness by pointer and by Enter", async () => {
    const methods = ["pointer", "keyboard"] as const;
    expect(methods).toHaveLength(2);
    for (const method of methods) {
      const host = mount("/home/u/.claude");
      const row = host.firstElementChild;
      if (!(row instanceof HTMLElement)) throw new Error("no row");
      expect(row.getAttribute("tabindex")).toBe("0");
      if (method === "pointer") await userEvent.click(row);
      else {
        row.focus();
        await userEvent.keyboard("{Enter}");
      }
      const nav = useNavStore.getState();
      expect(nav.page, method).toBe("library");
      expect(nav.libraryFilter?.harness, method).toBe("claude");
    }
  });

  // The control: a harness that is not installed has nothing to show, so
  // its row is a statement and stays out of the tab order.
  it("leaves a row for a harness that is not installed closed", async () => {
    const host = mount(null);
    const row = host.firstElementChild;
    if (!(row instanceof HTMLElement)) throw new Error("no row");
    expect(row.getAttribute("tabindex")).toBeNull();
    await userEvent.click(row);
    expect(useNavStore.getState().page).toBe("home");
  });
});
