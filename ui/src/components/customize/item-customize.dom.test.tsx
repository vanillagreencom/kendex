// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import type { Scope } from "@/bindings";
import { ItemCustomize } from "@/components/customize/item-customize";
import { CUSTOMIZED_MARK } from "@/lib/copy-customize";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const empty = { schema: 1, install: {} };
const withSetting = { ...empty, "skill-instructions": { gh: "mine" } };

const rows = [VG, HYPR].map((scope) => ({
  scope,
  kind: "skill",
  name: "gh",
  source: "cat",
  repo: "o/r",
  repoIdentity: "o/r",
  current: null,
  latest: null,
  updateAvailable: false,
  pinned: false,
  holdOwner: null,
  ignored: false,
  blockedByLocalEdit: false,
  editedHarnesses: [],
  forkableHarness: null,
  canDiscard: false,
  forked: false,
}));

const seed = (saved: Record<string, unknown>) => {
  useUpdatesStore.setState({ rows: rows as never, loaded: true });
  useEditorStore.setState({
    scope: VG,
    draft: saved["/work/vg"] as never,
    saved: saved as never,
  });
};

const tab = () =>
  mount(
    <ItemCustomize
      kind="skill"
      name="gh"
      scopes={[VG, HYPR]}
      harnesses={["claude"]}
    />,
  );

/** The place each chip names, and only the chips carrying the mark. */
const markedPlaces = (host: HTMLElement) =>
  [...host.querySelectorAll("button[aria-pressed]")]
    .map((pill) => pill.textContent ?? "")
    .filter((text) => text.includes(CUSTOMIZED_MARK))
    .map((text) => text.replace(CUSTOMIZED_MARK, ""));

// Chips that look alike whatever a place holds make "which of these three
// is mine" a question you answer by opening each one and reading four
// sections — and let this tab and the Library row say different things
// about the same package.
describe("the place chips", () => {
  beforeEach(() => {
    useEditorStore.setState({ saved: {}, draft: null });
    useUpdatesStore.setState({ rows: [], loaded: false });
  });

  it("marks the place that holds something and leaves the other plain", () => {
    seed({ "/work/vg": withSetting, "/work/hyprtrade": empty });
    expect(markedPlaces(tab())).toEqual(["vg"]);
  });

  it("marks nothing where no place holds anything", () => {
    seed({ "/work/vg": empty, "/work/hyprtrade": empty });
    expect(markedPlaces(tab())).toEqual([]);
  });
});
