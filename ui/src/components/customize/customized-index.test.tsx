// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
import {
  CUSTOMIZED_CHECKING,
  CUSTOMIZED_UPDATES_UNCHECKED,
  NOT_INSTALLED_HERE,
  NOTHING_CUSTOMIZED,
  REMOVE_CUSTOMIZATION,
} from "@/lib/copy-customize";
import type { CustomizedHere } from "@/lib/customized-places";
import type { UpdatesReadState } from "@/lib/updates-read-state";
import { useScanStore } from "@/stores/scan";
import { CustomizedIndex } from "./customized-index";

(
  globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

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
  description: "about gh",
  tags: [],
});

const row = (over: Partial<CustomizedHere> = {}): CustomizedHere => ({
  kind: "skill",
  name: "gh",
  edited: true,
  forked: false,
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
const mounted: Root[] = [];
const render = (
  items: CustomizedHere[],
  updates: UpdatesReadState = "landed",
): string => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  mounted.push(root);
  act(() => {
    root.render(
      <CustomizedIndex
        items={items}
        scope={VG}
        updates={updates}
        onRemove={() => {}}
      />,
    );
  });
  return host.innerHTML;
};

afterEach(() => {
  act(() => {
    for (const root of mounted) root.unmount();
  });
  mounted.length = 0;
  document.body.replaceChildren();
});

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

  it("says how a hand-edited package was customized and opens it", () => {
    const html = render([row()]);
    expect(html).toContain("Skill · Edited by you");
    expect(html).toContain("Open");
    expect(html).not.toContain(NOT_INSTALLED_HERE);
  });

  // Remove clears the settings overlay and nothing else, so a row with no
  // settings to clear does not offer it.
  it("offers Remove only where settings exist to remove", () => {
    useScanStore.setState({ result: null });
    const bare = render([row({ edited: false, forked: true })]);
    expect(bare).toContain(NOT_INSTALLED_HERE);
    expect(bare).not.toContain(REMOVE_CUSTOMIZATION);
    const withSettings = render([
      row({
        edited: false,
        customization: { ...row().customization, instructions: "x" },
      }),
    ]);
    expect(withSettings).toContain(REMOVE_CUSTOMIZATION);
  });

  // "Nothing yet" is a claim about the place, and the hand-edit facts it
  // rests on arrive with the update read. Before that read lands the list
  // is the manifest's alone, so the section says it is checking; after a
  // failure, that packages may be missing. Either note sits under
  // whatever the manifest alone could list.
  it("claims nothing is customized only after the update read lands", () => {
    const pending = render([], "pending");
    expect(pending).toContain(CUSTOMIZED_CHECKING);
    expect(pending).not.toContain(NOTHING_CUSTOMIZED);
    const failed = render([], "failed");
    expect(failed).toContain(CUSTOMIZED_UPDATES_UNCHECKED);
    expect(failed).not.toContain(NOTHING_CUSTOMIZED);
    const some = render([row({ edited: false })], "failed");
    expect(some).toContain("gh");
    expect(some).toContain(CUSTOMIZED_UPDATES_UNCHECKED);
    const landed = render([], "landed");
    expect(landed).toContain(NOTHING_CUSTOMIZED);
    expect(landed).not.toContain(CUSTOMIZED_CHECKING);
  });
});
