import type { HarnessId, ItemKind, Scope } from "@/bindings";
import { InstructionBox } from "@/components/customize/instruction-box";
import { ItemSettings } from "@/components/customize/item-settings";
import { ItemSkills } from "@/components/customize/item-skills";
import { StaleNote } from "@/components/customize/stale-note";
import { Pill } from "@/components/pill";
import { Section } from "@/components/section";
import { StatusDot } from "@/components/status-dot";
import { StatusNote } from "@/components/status-note";
import {
  ADDITIONAL_HELP,
  ADDITIONAL_LABEL,
  CUSTOMIZED_MARK,
  LAUNCH_HELP,
  LAUNCH_LABEL,
  SAVE_FIRST,
  SETTINGS_SECTION,
  SKILL_INSTRUCTIONS_HELP,
  SKILL_INSTRUCTIONS_LABEL,
  SKILLS_SECTION,
  WRITTEN_INTO,
} from "@/lib/copy-customize";
import { itemCustomization, sharedCustomization } from "@/lib/customization";
import {
  manifestsForEditing,
  placeStandings,
  placesSource,
} from "@/lib/customized-places";
import { setInstruction } from "@/lib/editor-draft";
import { scopeName } from "@/lib/labels";
import { scopeKey } from "@/lib/scope";
import { useEditorStore } from "@/stores/editor";
import { useUpdatesStore } from "@/stores/updates";

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
  const {
    scope,
    draft,
    saved,
    inventory,
    dirty,
    error,
    stale,
    setScope,
    load,
    edit,
  } = useEditorStore();
  const rows = useUpdatesStore((s) => s.rows);
  const updatesLoaded = useUpdatesStore((s) => s.loaded);

  const mine = itemCustomization(draft, kind, name);
  const shared = sharedCustomization(draft);
  const tools = (inventory?.harnesses ?? []).filter((id) =>
    harnesses.includes(id),
  );
  // The chips answer the same question the Library row does, by the same
  // rule: a tab whose places all look alike makes "which of these three is
  // mine" a matter of opening each one and reading four sections. The open
  // draft stands in for its saved manifest, so a change made here marks
  // its chip before it is saved.
  const customizedIn = new Set(
    placeStandings(
      placesSource(
        manifestsForEditing(saved, draft, scope),
        rows,
        updatesLoaded,
      ),
      kind,
      name,
      scopes,
    )
      .filter((standing) => standing.standing === "customized")
      .map((standing) => scopeKey(standing.scope)),
  );

  return (
    <div className="flex flex-col gap-8 pt-2">
      {stale ? <StaleNote onReload={() => void load()} /> : null}
      {error ? (
        <StatusNote tone="critical" title="That change couldn't be saved">
          <span className="whitespace-pre-wrap">{error}</span>
        </StatusNote>
      ) : null}
      {scopes.length > 1 ? (
        <div className="flex flex-wrap items-center gap-1.5">
          {scopes.map((where) => (
            <Pill
              key={scopeKey(where)}
              selected={scopeKey(where) === scopeKey(scope)}
              disabled={dirty}
              title={dirty ? SAVE_FIRST : undefined}
              onClick={() => void setScope(where)}
            >
              {scopeName(where)}
              {customizedIn.has(scopeKey(where)) ? (
                <>
                  <StatusDot tone="customized" className="size-1.5" />
                  {/* Colour is never the only carrier of the fact. */}
                  <span className="sr-only">{CUSTOMIZED_MARK}</span>
                </>
              ) : null}
            </Pill>
          ))}
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
