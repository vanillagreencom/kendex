// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import type { EditorInventory, Scope } from "@/bindings";
import { ItemCustomize } from "@/components/customize/item-customize";
import { CUSTOMIZED_MARK, skillsInherited } from "@/lib/copy-customize";
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

// Which agents inherit an [agent-skills] row from which is the engine's
// rule. The tab reads the answer it is handed, keyed to the place it is
// open at, and knows nothing about how it was reached.
describe("the skills a place declares", () => {
  const inventory = (
    declaredSkillRows: EditorInventory["declaredSkillRows"],
  ): EditorInventory =>
    ({
      declaredAgents: [],
      declaredSkills: [],
      availableSkills: ["dev", "worktree"],
      automaticSkills: { "reviewer-rust": ["dev"] },
      declaredSkillRows,
      harnesses: ["claude"],
      hookEvents: [],
    }) as unknown as EditorInventory;

  const openAt = (
    scope: Scope,
    inventories: Record<string, EditorInventory>,
  ) => {
    useUpdatesStore.setState({ rows: [], loaded: true });
    useEditorStore.setState({
      scope,
      draft: empty as never,
      saved: { "/work/vg": empty as never },
      inventories,
    });
    return mount(
      <ItemCustomize
        kind="agent"
        name="reviewer-rust"
        scopes={[VG]}
        harnesses={["claude"]}
      />,
    );
  };

  it("names the row the engine says this agent reads", () => {
    const host = openAt(VG, {
      "/work/vg": inventory({
        "reviewer-rust": { skills: ["worktree"], under: "rust" },
      }),
    });
    expect(host.textContent).toContain(skillsInherited("rust"));
    expect(host.textContent).toContain("worktree");
  });

  // The inventory belongs to a place. Read loose, another place's answer
  // would offer this agent an assignment nobody set here.
  it("reads no other place's answer", () => {
    const host = openAt(HYPR, {
      "/work/vg": inventory({
        "reviewer-rust": { skills: ["worktree"], under: "rust" },
      }),
    });
    expect(host.textContent).not.toContain(skillsInherited("rust"));
  });
});
