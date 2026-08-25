// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
import {
  CUSTOMIZED_UPDATES_UNCHECKED,
  NOT_INSTALLED_HERE,
  NOTHING_CUSTOMIZED,
  REMOVE_CUSTOMIZATION,
} from "@/lib/copy-customize";
import type { CustomizedHere } from "@/lib/customized-places";
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
const render = (items: CustomizedHere[], updatesFailed = false): string => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  mounted.push(root);
  act(() => {
    root.render(
      <CustomizedIndex
        items={items}
        scope={VG}
        updatesFailed={updatesFailed}
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

  // With the update read failed, an empty list is not "nothing customized":
  // the hand-edit facts never arrived. The note replaces that claim, and
  // sits under whatever the manifest alone could list.
  it("says hand edits cannot be listed after a failed update read", () => {
    const empty = render([], true);
    expect(empty).toContain(CUSTOMIZED_UPDATES_UNCHECKED);
    expect(empty).not.toContain(NOTHING_CUSTOMIZED);
    const some = render([row({ edited: false })], true);
    expect(some).toContain("gh");
    expect(some).toContain(CUSTOMIZED_UPDATES_UNCHECKED);
    expect(render([], false)).toContain(NOTHING_CUSTOMIZED);
  });
});
