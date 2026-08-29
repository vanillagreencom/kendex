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
  inventory,
  onChange,
}: {
  agent: string;
  /** null while the catalog's own assignment stands. */
  chosen: string[] | null;
  inventory: EditorInventory | null;
  onChange: (change: (draft: Draft) => Draft) => void;
}) {
  // What the catalog gave this agent, so the automatic state names the
  // skills instead of leaving an empty box that reads as "none".
  // Undefined is "nothing recorded here", which is not "none".
  const automatic = inventory?.automaticSkills[agent];
  const shown = chosen ?? automatic ?? [];
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
  const note = chosen
    ? SKILLS_CHOSEN
    : automatic === undefined
      ? SKILLS_AUTOMATIC_UNRECORDED
      : automatic.length > 0
        ? SKILLS_AUTOMATIC
        : SKILLS_AUTOMATIC_NONE;

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
