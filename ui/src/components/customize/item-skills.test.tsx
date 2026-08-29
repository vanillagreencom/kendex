import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { EditorInventory } from "@/bindings";
import { ItemSkills } from "@/components/customize/item-skills";
import {
  SKILLS_AUTOMATIC,
  SKILLS_AUTOMATIC_NONE,
  SKILLS_AUTOMATIC_UNRECORDED,
  skillsInherited,
} from "@/lib/copy-customize";

const inventory = (
  automaticSkills: Record<string, string[]>,
): EditorInventory =>
  ({
    declaredAgents: [],
    declaredSkills: [],
    availableSkills: ["dev", "github", "worktree"],
    automaticSkills,
    declaredSkillRows: {},
    harnesses: ["claude"],
    hookEvents: [],
  }) as unknown as EditorInventory;

const render = (
  chosen: string[] | null,
  automaticSkills: Record<string, string[]>,
  inherited: { skills: string[]; under: string } | null = null,
  agent = "orch",
) => withInventory(inventory(automaticSkills), chosen, inherited, agent);

const withInventory = (
  held: EditorInventory | null,
  chosen: string[] | null,
  inherited: { skills: string[]; under: string } | null = null,
  agent = "orch",
) =>
  renderToStaticMarkup(
    <ItemSkills
      agent={agent}
      chosen={chosen}
      inherited={inherited}
      inventory={held}
      onChange={() => {}}
    />,
  );

// An automatic list drawn as an empty box reads as "this agent has no
// skills", which is a different claim from the one the section is making.
describe("the automatic state", () => {
  it("names the skills the catalog gives the agent", () => {
    const shown = render(null, { orch: ["dev", "github"] });
    expect(shown).toContain(SKILLS_AUTOMATIC);
    expect(shown).toContain("dev");
    expect(shown).toContain("github");
  });

  it("offers no Remove on a list that is not the reader's", () => {
    expect(render(null, { orch: ["dev"] })).not.toContain("Remove dev");
    expect(render(["dev"], {})).toContain("Remove dev");
  });

  it("says so plainly where the catalog assigns nothing", () => {
    const shown = render(null, { orch: [] });
    expect(shown).toContain(SKILLS_AUTOMATIC_NONE);
  });

  // Nothing recorded is not the same fact as nothing assigned, and the
  // section may not print the second over the first.
  it("keeps an unrecorded assignment apart from an empty one", () => {
    const shown = render(null, {});
    expect(shown).toContain(SKILLS_AUTOMATIC_UNRECORDED);
    expect(shown).not.toContain(SKILLS_AUTOMATIC_NONE);
  });
});

// A reviewer agent with no row of its own renders the row set on its base
// agent. Naming the catalog's list there says the agent gets skills it
// does not get, over a list the person wrote by hand.
describe("a row this agent inherits", () => {
  const inherited = { skills: ["worktree"], under: "rust" };

  it("names the inherited list, not the catalog's", () => {
    const shown = render(
      null,
      { "reviewer-rust": ["dev"] },
      inherited,
      "reviewer-rust",
    );
    expect(shown).toContain("worktree");
    expect(shown).not.toContain(">dev<");
    expect(shown).toContain(skillsInherited("rust"));
    expect(shown).not.toContain(SKILLS_AUTOMATIC);
  });

  // The row lives under another agent, and the controls here write this
  // agent's own. An X that silently changed nothing is worse than none.
  it("offers no Remove on a row that is not this agent's", () => {
    const shown = render(null, {}, inherited, "reviewer-rust");
    expect(shown).not.toContain("Remove worktree");
  });

  it("prefers this agent's own row when it has one", () => {
    const shown = render(["dev"], {}, inherited, "reviewer-rust");
    expect(shown).toContain("Remove dev");
    expect(shown).not.toContain(skillsInherited("rust"));
  });
});

// The editor drops a place's inventory when its read fails, so "no entry
// for this agent" and "no inventory at all" both arrive as undefined.
// Only the first is a fact about the agent.
describe("a place whose inventory was not read", () => {
  it("makes no claim about what the agent gets", () => {
    const shown = withInventory(null, null);
    expect(shown).not.toContain(SKILLS_AUTOMATIC_UNRECORDED);
    expect(shown).not.toContain(SKILLS_AUTOMATIC_NONE);
    expect(shown).not.toContain(SKILLS_AUTOMATIC);
  });

  // The claim is still made where an inventory was read and holds nothing
  // for this agent — that is a fact, and dropping it would lose it.
  it("still says so where the inventory was read and has no entry", () => {
    expect(render(null, {})).toContain(SKILLS_AUTOMATIC_UNRECORDED);
  });
});
