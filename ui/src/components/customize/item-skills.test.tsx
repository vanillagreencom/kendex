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

// The note and removal affordance depend on which assignment this place knows.
describe("the skill assignment this place shows", () => {
  it("distinguishes automatic, chosen, inherited and unread assignments", () => {
    const inherited = { skills: ["worktree"], under: "rust" };
    const rows = [
      {
        name: "automatic list",
        chosen: null,
        automatic: { orch: ["dev", "github"] },
        contains: [SKILLS_AUTOMATIC, "dev", "github"],
        absent: [],
      },
      {
        name: "automatic list is not removable",
        chosen: null,
        automatic: { orch: ["dev"] },
        contains: [],
        absent: ["Remove dev"],
      },
      {
        name: "chosen list is removable",
        chosen: ["dev"],
        automatic: {},
        contains: ["Remove dev"],
        absent: [],
      },
      {
        name: "empty assignment",
        chosen: null,
        automatic: { orch: [] },
        contains: [SKILLS_AUTOMATIC_NONE],
        absent: [],
      },
      {
        name: "unrecorded assignment in a read inventory",
        chosen: null,
        automatic: {},
        contains: [SKILLS_AUTOMATIC_UNRECORDED],
        absent: [SKILLS_AUTOMATIC_NONE],
      },
      {
        name: "inherited list overrides automatic",
        chosen: null,
        automatic: { "reviewer-rust": ["dev"] },
        inherited,
        agent: "reviewer-rust",
        contains: ["worktree", skillsInherited("rust")],
        absent: [">dev<", SKILLS_AUTOMATIC],
      },
      {
        name: "inherited list is not removable",
        chosen: null,
        automatic: {},
        inherited,
        agent: "reviewer-rust",
        contains: [],
        absent: ["Remove worktree"],
      },
      {
        name: "own row overrides inherited",
        chosen: ["dev"],
        automatic: {},
        inherited,
        agent: "reviewer-rust",
        contains: ["Remove dev"],
        absent: [skillsInherited("rust")],
      },
      {
        name: "unread inventory makes no assignment claim",
        chosen: null,
        automatic: null,
        contains: [],
        absent: [
          SKILLS_AUTOMATIC_UNRECORDED,
          SKILLS_AUTOMATIC_NONE,
          SKILLS_AUTOMATIC,
        ],
      },
    ];
    expect(rows).toHaveLength(9);
    for (const entry of rows) {
      const shown =
        entry.automatic === null
          ? withInventory(null, entry.chosen)
          : render(
              entry.chosen,
              entry.automatic as Record<string, string[]>,
              entry.inherited,
              entry.agent,
            );
      expect(
        {
          present: entry.contains.filter((text) => shown.includes(text)),
          forbidden: entry.absent.filter((text) => shown.includes(text)),
        },
        entry.name,
      ).toEqual({ present: entry.contains, forbidden: [] });
    }
  });
});
