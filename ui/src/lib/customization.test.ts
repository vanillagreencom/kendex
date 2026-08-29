import { describe, expect, it } from "vitest";
import {
  canCustomize,
  clearItemCustomization,
  customizedItems,
  declaredSkillsRow,
  frontmatterFor,
  isCustomized,
  itemCustomization,
  sharedCustomization,
  skillsBaseAgent,
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

// The engine renders a `reviewer-` agent with no row of its own from its
// base agent's row (`crates/core/src/engine/desired_agent.rs`,
// `declared_skills`). A reader here that asked for the exact name alone
// called a real assignment absent.
describe("declaredSkillsRow", () => {
  const rows = (agentSkills: Record<string, string[]>): Draft => ({
    ...emptyDraft(),
    "agent-skills": agentSkills,
  });

  it("returns the agent's own row under its own name", () => {
    expect(declaredSkillsRow(rows({ rust: ["worktree"] }), "rust")).toEqual({
      skills: ["worktree"],
      under: "rust",
    });
  });

  it("falls back to the base agent's row for a reviewer agent", () => {
    expect(
      declaredSkillsRow(rows({ rust: ["worktree"] }), "reviewer-rust"),
    ).toEqual({ skills: ["worktree"], under: "rust" });
  });

  it("prefers the agent's own row over the one it would inherit", () => {
    const both = rows({ rust: ["worktree"], "reviewer-rust": ["dev"] });
    expect(declaredSkillsRow(both, "reviewer-rust")).toEqual({
      skills: ["dev"],
      under: "reviewer-rust",
    });
  });

  // An empty row is a declaration saying "none", not an absent one.
  it("keeps an empty row as a declaration", () => {
    expect(declaredSkillsRow(rows({ rust: [] }), "rust")).toEqual({
      skills: [],
      under: "rust",
    });
  });

  it("says nothing where no row reaches this agent", () => {
    expect(
      declaredSkillsRow(rows({ orch: ["dev"] }), "reviewer-rust"),
    ).toBeNull();
    expect(declaredSkillsRow(emptyDraft(), "rust")).toBeNull();
    expect(declaredSkillsRow(null, "rust")).toBeNull();
  });

  // Only `reviewer-` is stripped; nothing else inherits.
  it("gives no other prefix a base agent", () => {
    expect(skillsBaseAgent("reviewer-rust")).toBe("rust");
    expect(skillsBaseAgent("planner-rust")).toBe("planner-rust");
    expect(skillsBaseAgent("reviewer")).toBe("reviewer");
  });
});
