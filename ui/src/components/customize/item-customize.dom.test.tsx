// @vitest-environment jsdom
import { beforeEach, describe, expect, it } from "vitest";
import type { EditorInventory, Scope, ScopeSettings } from "@/bindings";
import { ItemCustomize } from "@/components/customize/item-customize";
import { CUSTOMIZED_MARK, skillsInherited } from "@/lib/copy-customize";
import { READ_LANDED, READ_PENDING } from "@/lib/read-state";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";
import { mount } from "@/test/dom";

const VG: Scope = { scope: "project", root: "/work/vg" };
const HYPR: Scope = { scope: "project", root: "/work/hyprtrade" };

const empty = { schema: 1, install: {} };
const withSetting = { ...empty, "skill-instructions": { gh: "mine" } };
// The row is set on `rust`; `reviewer-rust` only reaches it.
const baseRow = { ...empty, "agent-skills": { rust: ["worktree"] } };

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

/** gh declaring one key, standing at `value` in this place's file. */
const declares = (value: string): ScopeSettings => ({
  applies: true,
  base: "b1",
  skills: [
    {
      skill: "gh",
      template: {
        state: "rows",
        rows: [
          {
            key: "GH_MODE",
            explainer: ["what it does"],
            default: "enforce",
            current: { state: "value", value, line: 3 },
          },
        ],
      },
    },
  ],
});

// Both places read and both at the package default, so only a draft can
// move a chip.
const savedSettings = {
  "/work/vg": declares("enforce"),
  "/work/hyprtrade": declares("enforce"),
};

const seed = (saved: Record<string, unknown>) => {
  useUpdatesStore.setState({ rows: rows as never, read: READ_LANDED });
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
    useEditorStore.setState({
      saved: {},
      draft: null,
      savedSettings,
      settingsEdits: [],
    });
    useUpdatesStore.setState({ rows: [], read: READ_PENDING });
  });

  it("marks the place that holds something and leaves the other plain", () => {
    seed({ "/work/vg": withSetting, "/work/hyprtrade": empty });
    expect(markedPlaces(tab())).toEqual(["vg"]);
  });

  it("marks nothing where no place holds anything", () => {
    seed({ "/work/vg": empty, "/work/hyprtrade": empty });
    expect(markedPlaces(tab())).toEqual([]);
  });

  /// The manifest draft beside them already moves these chips before a
  /// save. A settings value typed here has to move them too, or one tab
  /// answers two ways about the same place depending which draft holds
  /// the change.
  it("marks the open place from a settings value not yet saved", () => {
    seed({ "/work/vg": empty, "/work/hyprtrade": empty });
    useEditorStore.setState({ savedSettings, settingsEdits: [] });
    expect(markedPlaces(tab())).toEqual([]);

    useEditorStore.setState({
      savedSettings,
      settingsEdits: [
        {
          skill: "gh",
          key: "GH_MODE",
          value: { kind: "set", value: "advise" },
        },
      ],
    });
    expect(markedPlaces(tab())).toEqual(["vg"]);
  });

  it("unmarks it again on a reset not yet saved", () => {
    seed({ "/work/vg": empty, "/work/hyprtrade": empty });
    const advised = {
      "/work/vg": declares("advise"),
      "/work/hyprtrade": declares("enforce"),
    };
    useEditorStore.setState({ savedSettings: advised, settingsEdits: [] });
    expect(markedPlaces(tab())).toEqual(["vg"]);

    useEditorStore.setState({
      savedSettings: advised,
      settingsEdits: [
        { skill: "gh", key: "GH_MODE", value: { kind: "reset" } },
      ],
    });
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
    useUpdatesStore.setState({ rows: [], read: READ_LANDED });
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

// The two questions on this tab, and the rule that keeps them apart: the
// chip says whether you changed this agent here, the Skills section says
// what it gets and from where. A row set on another agent is named by the
// second and not counted by the first.
describe("an agent whose only row is set on another agent", () => {
  const agentRows = [VG, HYPR].map((scope) => ({
    ...(rows[0] as Record<string, unknown>),
    scope,
    kind: "agent",
    name: "reviewer-rust",
  }));

  it("names the row without marking the place", () => {
    useUpdatesStore.setState({ rows: agentRows as never, read: READ_LANDED });
    useEditorStore.setState({
      scope: VG,
      draft: baseRow as never,
      saved: {
        "/work/vg": baseRow as never,
        "/work/hyprtrade": empty as never,
      },
      inventories: {
        "/work/vg": {
          availableSkills: [],
          automaticSkills: {},
          declaredSkillRows: {
            "reviewer-rust": { skills: ["worktree"], under: "rust" },
          },
          harnesses: ["claude"],
        } as unknown as EditorInventory,
      },
    });
    const host = mount(
      <ItemCustomize
        kind="agent"
        name="reviewer-rust"
        scopes={[VG, HYPR]}
        harnesses={["claude"]}
      />,
    );
    expect(host.textContent).toContain(skillsInherited("rust"));
    expect(markedPlaces(host)).toEqual([]);
  });
});
