import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { EditorInventory } from "@/bindings";
import { ItemSkills } from "@/components/customize/item-skills";
import {
  SKILLS_AUTOMATIC,
  SKILLS_AUTOMATIC_NONE,
  SKILLS_AUTOMATIC_UNRECORDED,
} from "@/lib/copy-customize";

const inventory = (
  automaticSkills: Record<string, string[]>,
): EditorInventory =>
  ({
    declaredAgents: [],
    declaredSkills: [],
    availableSkills: ["dev", "github", "worktree"],
    automaticSkills,
    harnesses: ["claude"],
    hookEvents: [],
  }) as unknown as EditorInventory;

const render = (
  chosen: string[] | null,
  automaticSkills: Record<string, string[]>,
) =>
  renderToStaticMarkup(
    <ItemSkills
      agent="orch"
      chosen={chosen}
      inventory={inventory(automaticSkills)}
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
