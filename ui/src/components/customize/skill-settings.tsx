import type { ScopeSettings, SettingsEdit } from "@/bindings";
import { SkillSettingRow } from "@/components/customize/skill-setting-row";
import { Section } from "@/components/section";
import { StatusNote } from "@/components/status-note";
import {
  SETTINGS_HELP,
  SETTINGS_SECTION,
  SETTINGS_TEMPLATE_INVALID,
  SETTINGS_TEMPLATE_INVALID_NOTE,
  SETTINGS_TEMPLATE_UNREADABLE,
  templateFindingLine,
} from "@/lib/copy-customize";
import { editIn, skillIn } from "@/lib/settings-rows";

/**
 * One skill's own settings at the place being edited: the keys its
 * template declares, and where this project's `kendex.settings.toml`
 * stands on each.
 *
 * A skill that declares none, and a place with no settings file at all —
 * global, where skills seed on a project install alone — get no section
 * rather than an empty one. Every other state gets a section that says
 * what it is: a template out of reach, and a template the strict reader
 * refuses, are answers about the template and say nothing about what the
 * file holds, because seeding is lenient and may have written those keys
 * anyway.
 */
export function SkillSettings({
  skill,
  settings,
  edits,
  onEdit,
}: {
  skill: string;
  /** The place's read, null until it lands or where it failed. */
  settings: ScopeSettings | null;
  edits: SettingsEdit[];
  onEdit: (edit: SettingsEdit) => void;
}) {
  const mine = skillIn(settings, skill);
  const template = mine?.template;
  if (!template || template.state === "no-template") return null;

  if (template.state === "unreadable") {
    return (
      <Section title={SETTINGS_SECTION}>
        <StatusNote tone="warning" title={SETTINGS_TEMPLATE_UNREADABLE}>
          {template.reason}
        </StatusNote>
      </Section>
    );
  }

  if (template.state === "invalid") {
    return (
      <Section title={SETTINGS_SECTION}>
        <StatusNote tone="warning" title={SETTINGS_TEMPLATE_INVALID}>
          <p>{SETTINGS_TEMPLATE_INVALID_NOTE}</p>
          <ul className="mt-2 flex flex-col gap-1">
            {template.findings.map((finding) => (
              <li key={`${finding.line}:${finding.problem}`}>
                {templateFindingLine(
                  finding.line,
                  finding.problem,
                  finding.fix,
                )}
              </li>
            ))}
          </ul>
        </StatusNote>
      </Section>
    );
  }

  if (template.rows.length === 0) return null;
  return (
    <Section title={SETTINGS_SECTION} description={SETTINGS_HELP}>
      <div className="flex flex-col divide-y">
        {template.rows.map((row) => (
          <SkillSettingRow
            key={row.key}
            skill={skill}
            row={row}
            edit={editIn(edits, skill, row.key)}
            onEdit={onEdit}
          />
        ))}
      </div>
    </Section>
  );
}
