// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Scope } from "@/bindings";
import {
  bundledWithLabel,
  FORKED_BADGE_HELP,
  FORKED_BADGE_LABEL,
  MISSING_FILES_BADGE_HELP,
  MISSING_FILES_BADGE_LABEL,
  vendorHelp,
} from "@/lib/copy";
import { UPDATE_AVAILABLE_BADGE } from "@/lib/copy-updates";
import { groupItems } from "@/lib/derive";
import { mount as mountTree } from "@/test/dom";
import { type InstalledColumns, InstalledRow } from "./installed-row";

// A row drawn with the room for everything it can say. Which columns
// the table can afford is `installed-view.tsx`'s answer, not a row's.
const EVERY_COLUMN: InstalledColumns = {
  tags: true,
  harnesses: true,
  from: true,
  updated: true,
};

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const item = (scope: Scope) => ({
  kind: "skill",
  name: "gh",
  scope,
  harness: "claude",
  path: `${scope.scope === "project" ? scope.root : ""}/.claude/skills/gh`,
  fileState: "file",
  enabled: true,
  origin: null,
  summary: "about gh",
  action: null,
  tags: [],
});

// One package the records account for, installed in two places. It takes a
// declared identity because that is what puts two places on one row: two
// copies nothing recorded are two unrelated files that happen to share a
// name, and the Library keeps those apart.
const group = groupItems([item(VG), item(HYPR)] as never, () => ({
  kind: "skill",
  name: "gh",
}))[0];

describe("opening a package from its Library row", () => {
  it("opens the intended target once and preserves a selected row drag", async () => {
    const rows = [
      {
        name: "name Enter",
        target: "name",
        keyboard: true,
        selected: false,
        calls: 1,
        args: [],
      },
      {
        name: "name click",
        target: "name",
        keyboard: false,
        selected: false,
        calls: 1,
      },
      {
        name: "row shortcut",
        target: "cell",
        keyboard: false,
        selected: false,
        calls: 1,
        args: [],
      },
      {
        name: "row Enter",
        target: "row",
        keyboard: true,
        selected: false,
        calls: 1,
        args: [],
      },
      {
        name: "selected name Enter",
        target: "name",
        keyboard: true,
        selected: true,
        calls: 1,
      },
      {
        name: "selected name click",
        target: "name",
        keyboard: false,
        selected: true,
        calls: 1,
      },
      {
        name: "selected row drag",
        target: "cell",
        keyboard: false,
        selected: true,
        calls: 0,
      },
      {
        name: "fork badge",
        target: "fork",
        keyboard: false,
        selected: false,
        calls: 1,
        args: [VG],
      },
    ];
    expect(rows).toHaveLength(8);
    for (const entry of rows) {
      vi.restoreAllMocks();
      const { host, onOpen } = mount(entry.target === "fork" ? [VG] : []);
      if (entry.selected)
        vi.spyOn(window, "getSelection").mockReturnValue({
          isCollapsed: false,
        } as Selection);
      const target =
        entry.target === "name"
          ? nameButton(host)
          : entry.target === "row"
            ? host.querySelector("tr")
            : entry.target === "cell"
              ? host.querySelectorAll("td")[1]
              : [...host.querySelectorAll("button")].find((button) =>
                  button.textContent?.startsWith(FORKED_BADGE_LABEL),
                );
      if (!target) throw new Error(`no ${entry.target} target`);
      if (entry.target === "fork")
        expect(target.textContent).toContain("in vg");
      if (entry.keyboard) {
        (target as HTMLElement).focus();
        await userEvent.keyboard("{Enter}");
      } else await userEvent.click(target);
      expect(onOpen, entry.name).toHaveBeenCalledTimes(entry.calls);
      if (entry.args !== undefined)
        expect(onOpen, entry.name).toHaveBeenCalledWith(...entry.args);
    }
  });
});

// A word the app made up — Forked, Bundled with Anthropic — says nothing to
// the person reading the row. Each one carries what it costs them, and it
// arrives on focus, not only under a pointer.
describe("the words a Library row's badges stand for", () => {
  // The nothing-before-focus half of every case here: a helper that read a
  // flyout already on screen would pass over a badge that explains itself
  // only under a pointer, which is the state this change is fixing.
  const openOn = (badge: HTMLElement): string | undefined => {
    expect(document.querySelector('[data-slot="tooltip-content"]')).toBeNull();
    act(() => badge.focus());
    return (
      document.querySelector('[data-slot="tooltip-content"]')?.textContent ??
      undefined
    );
  };

  it("opens the fork's meaning on focus", () => {
    const { host } = mount([VG]);
    const badge = [...host.querySelectorAll<HTMLElement>("button")].find((b) =>
      b.textContent?.startsWith(FORKED_BADGE_LABEL),
    );
    if (!badge) throw new Error("no fork badge");
    expect(openOn(badge)).toBe(FORKED_BADGE_HELP);
  });

  it("opens what a bundled package is on focus", () => {
    const bundled = groupItems(
      [{ ...item(VG), vendor: "Anthropic" }] as never,
      () => null,
    )[0];
    const host = mountTree(
      <tbody>
        <InstalledRow
          columns={EVERY_COLUMN}
          group={bundled}
          origin={null}
          forkedIn={[]}
          outOfDate={false}
          missingIn={[]}
          onOpen={() => {}}
          onOpenHarness={() => {}}
          onOpenPlace={() => {}}
        />
      </tbody>,
      { host: "table" },
    );
    const badge = [
      ...host.querySelectorAll<HTMLElement>('[data-slot="tooltip-trigger"]'),
    ].find((b) => b.textContent?.startsWith(bundledWithLabel("claude")));
    if (!badge) throw new Error("no bundled badge");
    expect(openOn(badge)).toBe(vendorHelp("Anthropic"));
  });
});

// The source has moved on from what is installed. A mark and not a
// control: the row's own click already opens the package, and the update
// itself is one flow wherever it is taken.
describe("the update mark", () => {
  it("marks a package the source has moved on from, and nothing else", () => {
    const cases = [
      { name: "out of date", outOfDate: true, marked: true },
      { name: "current", outOfDate: false, marked: false },
    ];
    expect(cases).toHaveLength(2);
    for (const one of cases) {
      const { host } = mount([], one.outOfDate);
      expect(host.textContent?.includes(UPDATE_AVAILABLE_BADGE), one.name).toBe(
        one.marked,
      );
    }
  });
});

// A file kendex installed is gone from one place. The badge names that
// place, says so on focus, and opens the package there — where the repair
// is — rather than marking the row and leaving the reader to find which
// of its places is broken.
describe("the missing files badge", () => {
  // A place whose copy is gone is one of the row's places, whether the
  // scan still sees a copy there or not, and each place once: the Where
  // count, its title and the badges read the same set, so a package seen
  // in two projects and gone from one of them and a third counts three.
  it("marks the place missing a file and opens the package there", () => {
    const other: Scope = { scope: "project", root: "/work/other" };
    const { host, onOpen } = mount([], false, [HYPR, other]);
    const where = host.querySelectorAll("td")[4];
    expect(where?.textContent).toBe("3 locations");
    expect(where?.getAttribute("title")).toBe(
      "/work/vg, /work/hyprtrade, /work/other",
    );
    const badge = [...host.querySelectorAll<HTMLElement>("button")].find((b) =>
      b.textContent?.startsWith(MISSING_FILES_BADGE_LABEL),
    );
    if (!badge) throw new Error("no missing files badge");
    expect(badge.textContent).toContain("in hyprtrade");
    expect(badge.textContent).toContain(MISSING_FILES_BADGE_HELP);
    act(() => badge.click());
    expect(onOpen).toHaveBeenCalledWith(HYPR);
  });

  it("marks nothing where every file is in place", () => {
    const { host } = mount();
    expect(host.textContent?.includes(MISSING_FILES_BADGE_LABEL)).toBe(false);
  });
});

// Every other thing a row names opens too: the harness chip opens the
// harness, the place opens the place, the marketplace opens the
// marketplace. Each is a different target from the row's own, so a row
// that opened the package from all of them would still pass the test above.
describe("the other things a Library row names", () => {
  it("opens each from the chip, the place and the marketplace", async () => {
    const opened: string[] = [];
    // One place, so the Where cell names a place rather than counting
    // several.
    const host = mountTree(
      <tbody>
        <InstalledRow
          columns={EVERY_COLUMN}
          group={groupItems([item(VG)] as never, () => null)[0]}
          origin={{
            origin: "marketplace",
            source: "kendex",
            repo: "vg/kendex",
          }}
          forkedIn={[]}
          outOfDate={false}
          missingIn={[]}
          onOpen={() => opened.push("package")}
          onOpenHarness={(harness) => opened.push(`harness:${harness}`)}
          onOpenPlace={(scope) => opened.push(`place:${scope.scope}`)}
          onOpenFrom={() => opened.push("marketplace")}
        />
      </tbody>,
      { host: "table" },
    );
    const named = (text: string) => {
      const found = [...host.querySelectorAll("button")].find(
        (button) =>
          button.textContent === text ||
          button.getAttribute("aria-label") === text,
      );
      if (!found) throw new Error(`no button for ${text}`);
      return found;
    };

    await userEvent.click(named("Claude Code"));
    await userEvent.click(named("vg"));
    await userEvent.click(named("kendex"));
    expect(opened).toEqual(["harness:claude", "place:project", "marketplace"]);
  });

  // The control: a place cell counting several places names none of them,
  // so it opens nothing — the package's own page lists them instead.
  it("leaves a row in several places with no place to open", () => {
    const host = mountTree(
      <tbody>
        <InstalledRow
          columns={EVERY_COLUMN}
          group={group}
          origin={null}
          forkedIn={[]}
          outOfDate={false}
          missingIn={[]}
          onOpen={() => {}}
          onOpenHarness={() => {}}
          onOpenPlace={() => {}}
        />
      </tbody>,
      { host: "table" },
    );
    const where = host.querySelectorAll("td")[4];
    expect(where?.textContent).toBe("2 locations");
    expect(where?.querySelector("button")).toBeNull();
  });
});

// Whether a click reaches the row, and what a keypress lands on, are
// questions about a live DOM that static markup cannot answer.
afterEach(() => {
  vi.restoreAllMocks();
});

const mount = (
  forkedIn: Scope[] = [],
  outOfDate = false,
  missingIn: Scope[] = [],
) => {
  const onOpen = vi.fn();
  // A table host, so the row is mounted inside the structure it renders
  // for rather than under a div.
  const host = mountTree(
    <tbody>
      <InstalledRow
        columns={EVERY_COLUMN}
        group={group}
        origin={null}
        forkedIn={forkedIn}
        outOfDate={outOfDate}
        missingIn={missingIn}
        onOpen={onOpen}
        onOpenHarness={() => {}}
        onOpenPlace={() => {}}
      />
    </tbody>,
    { host: "table" },
  );
  return { host, onOpen };
};

const nameButton = (host: HTMLElement) => {
  const name = Array.from(host.querySelectorAll("button")).find(
    (b) => b.textContent === "gh",
  );
  if (!name) throw new Error("the package name is not a button");
  return name;
};
