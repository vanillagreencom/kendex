import type { HarnessId, ItemKind, Scope } from "@/bindings";
import { InstructionBox } from "@/components/customize/instruction-box";
import { ItemSettings } from "@/components/customize/item-settings";
import { ItemSkills } from "@/components/customize/item-skills";
import { Pill } from "@/components/pill";
import { Section } from "@/components/section";
import { StatusDot } from "@/components/status-dot";
import { StatusNote } from "@/components/status-note";
import {
  ADDITIONAL_HELP,
  ADDITIONAL_LABEL,
  LAUNCH_HELP,
  LAUNCH_LABEL,
  placeStateLine,
  SETTINGS_SECTION,
  SKILL_INSTRUCTIONS_HELP,
  SKILL_INSTRUCTIONS_LABEL,
  SKILLS_SECTION,
  WRITTEN_INTO,
} from "@/lib/copy-customize";
import { itemCustomization, sharedCustomization } from "@/lib/customization";
import {
  type PlaceStanding,
  placeStandings,
  standingIn,
} from "@/lib/customized-places";
import { setInstruction } from "@/lib/editor-draft";
import { scopeName } from "@/lib/labels";
import { useEditingPlacesSource } from "@/lib/places-source";
import { scopeKey } from "@/lib/scope";
import { useEditorStore } from "@/stores/editor";

/** Everything kendex lets a person change about one installed package,
 *  on that package's own page. The same manifest the Customize page edits,
 *  sliced to this one name. */
export function ItemCustomize({
  kind,
  name,
  scopes,
  harnesses,
}: {
  kind: ItemKind;
  name: string;
  /** Where this package is installed; the first is the one opened. */
  scopes: Scope[];
  harnesses: HarnessId[];
}) {
  const { scope, draft, inventory, saving, error, setScope, edit } =
    useEditorStore();
  const places = useEditingPlacesSource();
  // Which places already carry changes, so switching to one is an informed
  // click rather than something you find out after arriving.
  const standings = placeStandings(places, kind, name, scopes);
  const stateLine = (standing: PlaceStanding) =>
    placeStateLine(scopeName(standing.scope, scopes), standing.state);
  const here = standingIn(standings, scope);

  const mine = itemCustomization(draft, kind, name);
  const shared = sharedCustomization(draft);
  const tools = (inventory?.harnesses ?? []).filter((id) =>
    harnesses.includes(id),
  );

  return (
    <div className="flex flex-col gap-8 pt-2">
      {error ? (
        <StatusNote tone="critical" title="That change couldn't be saved">
          <span className="whitespace-pre-wrap">{error}</span>
        </StatusNote>
      ) : null}
      {scopes.length > 1 ? (
        <div className="flex flex-col gap-2">
          <div className="flex flex-wrap items-center gap-1.5">
            {standings.map((standing) => (
              <Pill
                key={scopeKey(standing.scope)}
                selected={scopeKey(standing.scope) === scopeKey(scope)}
                // Switching place mid-save would attribute the outcome to
                // a place it is not about, the same reason the Customize
                // page's picker is gated. Unsaved typing is not a reason to
                // shut a chip: it travels to the place it belongs to.
                disabled={saving}
                title={stateLine(standing)}
                onClick={() => void setScope(standing.scope)}
              >
                {standing.state === "customized" ? (
                  <StatusDot tone="customized" />
                ) : null}
                {scopeName(standing.scope, scopes)}
                {/* The dot is the mark; these are its words, for anyone a
                    colour and a hover never reach. */}
                <span className="sr-only">{stateLine(standing)}</span>
              </Pill>
            ))}
          </div>
          {/* What the dot on the open chip means, said out loud — a hover
              is not a channel a touch reader has. */}
          {here ? (
            <p className="text-xs text-muted-foreground">{stateLine(here)}</p>
          ) : null}
        </div>
      ) : null}
      <Section title="Instructions" description={WRITTEN_INTO}>
        <div className="flex flex-col gap-6 pt-1">
          {kind === "skill" ? (
            <InstructionBox
              label={SKILL_INSTRUCTIONS_LABEL}
              help={SKILL_INSTRUCTIONS_HELP}
              value={mine.instructions}
              shared={shared.instructions}
              onChange={(text) =>
                edit((current) =>
                  setInstruction(current, "skill-instructions", name, text),
                )
              }
            />
          ) : (
            <>
              <InstructionBox
                label={LAUNCH_LABEL}
                help={LAUNCH_HELP}
                value={mine.launch}
                shared={shared.launch}
                onChange={(text) =>
                  edit((current) =>
                    setInstruction(
                      current,
                      "agent-launch-instructions",
                      name,
                      text,
                    ),
                  )
                }
              />
              <InstructionBox
                label={ADDITIONAL_LABEL}
                help={ADDITIONAL_HELP}
                value={mine.additional}
                shared={shared.additional}
                onChange={(text) =>
                  edit((current) =>
                    setInstruction(
                      current,
                      "agent-additional-instructions",
                      name,
                      text,
                    ),
                  )
                }
              />
            </>
          )}
        </div>
      </Section>
      {kind === "agent" ? (
        <>
          <Section title={SKILLS_SECTION}>
            <ItemSkills
              agent={name}
              chosen={mine.skills}
              inventory={inventory}
              onChange={edit}
            />
          </Section>
          <Section title={SETTINGS_SECTION}>
            <ItemSettings
              agent={name}
              customization={mine}
              harnesses={tools}
              onChange={edit}
            />
          </Section>
        </>
      ) : null}
    </div>
  );
}
