// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
import {
  CUSTOMIZED_CHECKING,
  CUSTOMIZED_UPDATES_UNCHECKED,
  NOT_INSTALLED_HERE,
  NOTHING_CUSTOMIZED,
  REMOVE_CUSTOMIZATION,
} from "@/lib/copy-customize";
import type { CustomizedHere } from "@/lib/customized-places";
import type { ReadStatus } from "@/lib/read-state";
import { useScanStore } from "@/stores/scan";
import { mount } from "@/test/dom";
import { CustomizedIndex } from "./customized-index";

const VG: Scope = { scope: "project", root: "/work/vg" };

const installed = (scope: Scope) => ({
  kind: "skill",
  name: "gh",
  scope,
  harness: "claude",
  path: "/work/vg/.claude/skills/gh",
  fileState: "file",
  enabled: true,
  origin: null,
  summary: "about gh",
  action: null,
  tags: [],
});

const row = (over: Partial<CustomizedHere> = {}): CustomizedHere => ({
  kind: "skill",
  name: "gh",
  edited: true,
  forked: false,
  values: false,
  customization: {
    launch: null,
    additional: null,
    instructions: null,
    skills: null,
    frontmatter: [],
  },
  ...over,
});

// Mounted rather than rendered to a string: a static render reads a
// zustand store's initial snapshot, and the scan store is what says
// whether a row's package is installed here.
const render = (
  items: CustomizedHere[],
  updates: ReadStatus = "landed",
): string =>
  mount(
    <CustomizedIndex
      items={items}
      scope={VG}
      updates={updates}
      onRemove={() => {}}
    />,
  ).innerHTML;

describe("CustomizedIndex", () => {
  beforeEach(() => {
    useScanStore.setState({
      result: {
        harnesses: [],
        items: [installed(VG)],
        missingProjects: [],
        warnings: [],
      } as never,
    });
  });

  // The row is the way into the package, so it opens — the name is a
  // button and the row itself takes focus — and carries no Open button.
  it("says how a hand-edited package was customized and opens it", () => {
    const html = render([row()]);
    expect(html).toContain("Skill · Edited by you");
    expect(html).toContain('tabindex="0"');
    expect(html).toContain(">gh</button>");
    expect(html).not.toContain(">Open");
    expect(html).not.toContain(NOT_INSTALLED_HERE);
  });

  // The control: a package that is not installed here has no page to
  // open, so its row is a statement rather than a way in.
  it("leaves a row with nothing to open unopenable", () => {
    useScanStore.setState({ result: null });
    const html = render([row()]);
    expect(html).toContain(NOT_INSTALLED_HERE);
    expect(html).not.toContain('tabindex="0"');
    expect(html).not.toContain(">gh</button>");
  });

  // Remove clears the settings overlay and nothing else, so a row with no
  // settings to clear does not offer it.
  it("offers Remove only where settings exist to remove", () => {
    useScanStore.setState({ result: null });
    const cases = [
      {
        name: "fork without settings",
        item: row({ edited: false, forked: true }),
        removable: false,
      },
      {
        name: "settings to clear",
        item: row({
          edited: false,
          customization: { ...row().customization, instructions: "x" },
        }),
        removable: true,
      },
    ];
    expect(cases).toHaveLength(2);
    for (const entry of cases) {
      const shown = render([entry.item]);
      expect(shown.includes(REMOVE_CUSTOMIZATION), entry.name).toBe(
        entry.removable,
      );
      if (!entry.removable) expect(shown).toContain(NOT_INSTALLED_HERE);
    }
  });

  // "Nothing yet" is a claim about the place, and the hand-edit facts it
  // rests on arrive with the update read. Before that read lands the list
  // is the manifest's alone, so the section says it is checking; after a
  // failure, that packages may be missing. Either note sits under
  // whatever the manifest alone could list.
  it("claims nothing is customized only after the update read lands", () => {
    const states: {
      name: string;
      items: CustomizedHere[];
      read: ReadStatus;
      present: string[];
      absent: string[];
    }[] = [
      {
        name: "pending empty place",
        items: [],
        read: "pending",
        present: [CUSTOMIZED_CHECKING],
        absent: [NOTHING_CUSTOMIZED],
      },
      {
        name: "failed empty place",
        items: [],
        read: "failed",
        present: [CUSTOMIZED_UPDATES_UNCHECKED],
        absent: [NOTHING_CUSTOMIZED],
      },
      {
        name: "failed place with a manifest row",
        items: [row({ edited: false })],
        read: "failed",
        present: ["gh", CUSTOMIZED_UPDATES_UNCHECKED],
        absent: [],
      },
      {
        name: "landed empty place",
        items: [],
        read: "landed",
        present: [NOTHING_CUSTOMIZED],
        absent: [CUSTOMIZED_CHECKING],
      },
    ];
    expect(states).toHaveLength(4);
    for (const state of states) {
      const shown = render(state.items, state.read);
      expect(
        {
          present: state.present.filter((text) => shown.includes(text)),
          forbidden: state.absent.filter((text) => shown.includes(text)),
        },
        state.name,
      ).toEqual({ present: state.present, forbidden: [] });
    }
  });
});
