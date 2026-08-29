import { describe, expect, it } from "vitest";
import {
  canCustomize,
  clearItemCustomization,
  customizedItems,
  frontmatterFor,
  isCustomized,
  itemCustomization,
  sharedCustomization,
} from "./customization";
import { type Draft, EMPTY_FRONTMATTER, emptyDraft } from "./editor-draft";

function draft(overrides: Partial<Draft> = {}): Draft {
  return {
    ...emptyDraft(),
    "agent-launch-instructions": { all: "read the plan", orch: "start here" },
    "agent-additional-instructions": { orch: "then stop" },
    "agent-skills": { orch: ["github", "docs"] },
    "skill-instructions": { all: "be brief", github: "use the CLI" },
    "agent-frontmatter": {
      claude: { orch: { ...EMPTY_FRONTMATTER, model: "opus" } },
      codex: { planner: { ...EMPTY_FRONTMATTER, effort: "high" } },
    },
    ...overrides,
  };
}

describe("itemCustomization", () => {
  it("collects everything set on one agent, and nothing set on another", () => {
    const orch = itemCustomization(draft(), "agent", "orch");
    expect(orch.launch).toBe("start here");
    expect(orch.additional).toBe("then stop");
    expect(orch.skills).toEqual(["github", "docs"]);
    expect(orch.frontmatter.map(([tool]) => tool)).toEqual(["claude"]);
    expect(frontmatterFor(orch, "claude").model).toBe("opus");
    expect(frontmatterFor(orch, "codex").model).toBeNull();
    expect(isCustomized(orch)).toBe(true);
  });

  it("reads a skill's instructions and never an agent's", () => {
    const github = itemCustomization(draft(), "skill", "github");
    expect(github.instructions).toBe("use the CLI");
    expect(github.launch).toBeNull();
    expect(isCustomized(itemCustomization(draft(), "skill", "deploy"))).toBe(
      false,
    );
  });

  it("keeps the shared row out of any one package's own", () => {
    expect(itemCustomization(draft(), "agent", "all").launch).toBe(
      "read the plan",
    );
    expect(sharedCustomization(draft()).launch).toBe("read the plan");
    expect(sharedCustomization(null).instructions).toBeNull();
  });

  it("offers nothing for kinds a manifest cannot change", () => {
    expect(canCustomize("hook")).toBe(false);
    expect(isCustomized(itemCustomization(draft(), "hook", "orch"))).toBe(
      false,
    );
  });
});

describe("customizedItems", () => {
  it("lists every customized package once, agents first, without the shared row", () => {
    expect(
      customizedItems(draft()).map((one) => `${one.kind}:${one.name}`),
    ).toEqual(["agent:orch", "agent:planner", "skill:github"]);
  });

  it("is empty when nothing has been written yet", () => {
    expect(customizedItems(emptyDraft())).toEqual([]);
    expect(customizedItems(null)).toEqual([]);
  });
});

describe("clearItemCustomization", () => {
  it("drops one agent's rows and leaves everyone else's standing", () => {
    const after = clearItemCustomization(draft(), "agent", "orch");
    expect(isCustomized(itemCustomization(after, "agent", "orch"))).toBe(false);
    expect(after["agent-launch-instructions"]).toEqual({
      all: "read the plan",
    });
    expect(after["agent-frontmatter"]).toEqual({
      codex: { planner: { ...EMPTY_FRONTMATTER, effort: "high" } },
    });
    expect(after["skill-instructions"]?.github).toBe("use the CLI");
  });

  it("drops a skill's instructions alone", () => {
    const after = clearItemCustomization(draft(), "skill", "github");
    expect(after["skill-instructions"]).toEqual({ all: "be brief" });
    expect(after["agent-skills"]).toEqual({ orch: ["github", "docs"] });
  });
});
