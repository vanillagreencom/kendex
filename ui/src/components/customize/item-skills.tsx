import { X } from "lucide-react";
import type { ReactNode } from "react";
import type { EditorInventory } from "@/bindings";
import { AddEntry } from "@/components/customize/controls";
import { Button } from "@/components/ui/button";
import {
  SKILLS_AUTOMATIC,
  SKILLS_AUTOMATIC_NONE,
  SKILLS_AUTOMATIC_UNRECORDED,
  SKILLS_BACK_TO_AUTOMATIC,
  SKILLS_CHOSEN,
  SKILLS_NONE_AVAILABLE,
  skillsInherited,
} from "@/lib/copy-customize";
import {
  clearAgentSkills,
  type Draft,
  setAgentSkill,
} from "@/lib/editor-draft";
import { cn } from "@/lib/utils";

/**
 * Which skills one agent gets. Chosen skills are chips and the rest live
 * behind a picker: an agent has a handful, a machine has dozens, and a wall
 * of unticked boxes hides the answer to "what does this agent have".
 */
export function ItemSkills({
  agent,
  chosen,
  inherited,
  inventory,
  onChange,
}: {
  agent: string;
  /** This agent's own `[agent-skills]` row; null where it has none. */
  chosen: string[] | null;
  /** The row this agent inherits and the agent it is set on — a reviewer
   *  agent with no row of its own renders its base agent's list, and that
   *  list, not the catalog's, is what it gets. Null when nothing is
   *  inherited, and never set alongside `chosen`. */
  inherited: { skills: string[]; under: string } | null;
  inventory: EditorInventory | null;
  onChange: (change: (draft: Draft) => Draft) => void;
}) {
  // What the catalog gave this agent, so the automatic state names the
  // skills instead of leaving an empty box that reads as "none".
  // Undefined is "nothing recorded here", which is not "none".
  const automatic = inventory?.automaticSkills[agent];
  const shown = chosen ?? inherited?.skills ?? automatic ?? [];
  const known = [
    ...new Set([
      ...(inventory?.declaredSkills ?? []),
      ...(inventory?.availableSkills ?? []),
      ...shown,
    ]),
  ].sort();
  // Against the reader's own list, not against what the catalog gave: in
  // the automatic state every known skill is still a choice to make, and
  // picking one the catalog already assigns is how a declaration that
  // keeps it starts.
  const unchosen = known.filter((skill) => !(chosen ?? []).includes(skill));
  const note = chosen ? SKILLS_CHOSEN : notChosen(inherited, automatic);

  return (
    <div className="flex flex-col gap-3">
      <p className="text-[13px] text-muted-foreground">{note}</p>
      {shown.length > 0 ? (
        <div className="flex flex-wrap gap-1.5">
          {shown.map((skill) => (
            <Chip key={skill} removable={chosen !== null}>
              {skill}
              {/* Removable only where the list is the reader's own. Taking
                  one off the catalog's list is choosing a list, which the
                  picker below is the way into — an X here would look like
                  an edit and quietly become a declaration. */}
              {chosen ? (
                <button
                  type="button"
                  aria-label={`Remove ${skill}`}
                  className="rounded-full p-0.5 text-muted-foreground hover:text-foreground"
                  onClick={() =>
                    onChange((draft) =>
                      setAgentSkill(draft, agent, skill, false),
                    )
                  }
                >
                  <X className="size-3.5" />
                </button>
              ) : null}
            </Chip>
          ))}
        </div>
      ) : null}
      <div className="flex flex-wrap items-center gap-2">
        {unchosen.length > 0 ? (
          <AddEntry
            placeholder="Add a skill…"
            options={unchosen}
            onAdd={(skill) =>
              onChange((draft) => setAgentSkill(draft, agent, skill, true))
            }
          />
        ) : (
          <p className="text-[13px] text-muted-foreground">
            {SKILLS_NONE_AVAILABLE}
          </p>
        )}
        {chosen ? (
          <Button
            variant="ghost"
            size="sm"
            onClick={() => onChange((draft) => clearAgentSkills(draft, agent))}
          >
            {SKILLS_BACK_TO_AUTOMATIC}
          </Button>
        ) : null}
      </div>
    </div>
  );
}

/** What the section says when this agent has no row of its own: the list
 *  it inherits, the catalog's, or that nothing is recorded here — three
 *  answers, and none of them may be printed over another. */
function notChosen(
  inherited: { under: string } | null,
  automatic: string[] | undefined,
): string {
  if (inherited) return skillsInherited(inherited.under);
  if (automatic === undefined) return SKILLS_AUTOMATIC_UNRECORDED;
  return automatic.length > 0 ? SKILLS_AUTOMATIC : SKILLS_AUTOMATIC_NONE;
}

function Chip({
  removable,
  children,
}: {
  removable: boolean;
  children: ReactNode;
}) {
  return (
    <span
      className={cn(
        "inline-flex h-7 items-center gap-1 rounded-full bg-secondary text-xs font-medium",
        removable ? "pr-1.5 pl-3" : "px-3",
      )}
    >
      {children}
    </span>
  );
}
