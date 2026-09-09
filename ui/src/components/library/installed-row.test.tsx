// @vitest-environment jsdom
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Scope } from "@/bindings";
import {
  bundledWithLabel,
  FORKED_BADGE_HELP,
  FORKED_BADGE_LABEL,
  vendorHelp,
} from "@/lib/copy";
import { groupItems } from "@/lib/derive";
import { mount as mountTree } from "@/test/dom";
import { InstalledRow } from "./installed-row";

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
  description: "about gh",
  tags: [],
});

const group = groupItems([item(VG), item(HYPR)] as never)[0];

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
    expect(rows).toHaveLength(7);
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
          : entry.target === "cell"
            ? host.querySelectorAll("td")[1]
            : [...host.querySelectorAll("button")].find((button) =>
                button.textContent?.startsWith(FORKED_BADGE_LABEL),
              );
      if (!target) throw new Error(`no ${entry.target} target`);
      if (entry.target === "fork")
        expect(target.textContent).toContain("in vg");
      if (entry.keyboard) {
        target.focus();
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
    const bundled = groupItems([
      { ...item(VG), vendor: "Anthropic" },
    ] as never)[0];
    const host = mountTree(
      <tbody>
        <InstalledRow
          group={bundled}
          origin={null}
          forkedIn={[]}
          onOpen={() => {}}
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

// Whether a click reaches the row, and what a keypress lands on, are
// questions about a live DOM that static markup cannot answer.
afterEach(() => {
  vi.restoreAllMocks();
});

const mount = (forkedIn: Scope[] = []) => {
  const onOpen = vi.fn();
  // A table host, so the row is mounted inside the structure it renders
  // for rather than under a div.
  const host = mountTree(
    <tbody>
      <InstalledRow
        group={group}
        origin={null}
        forkedIn={forkedIn}
        onOpen={onOpen}
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
