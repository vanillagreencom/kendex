import type {
  ScopeSettings,
  SecretEdit,
  SettingsEdit,
  SkillSettings as SkillSettingsRead,
} from "@/bindings";
import { SecretDestination } from "@/components/customize/secret-destination";
import { SecretFieldRow } from "@/components/customize/secret-field-row";
import { SkillSettingRow } from "@/components/customize/skill-setting-row";
import { Section } from "@/components/section";
import { StatusNote } from "@/components/status-note";
import {
  CONTESTED_KEYS,
  SECRETS_NEED_A_PROJECT,
  SECRETS_SECTION,
  SETTINGS_HELP,
  SETTINGS_SECTION,
  SETTINGS_TEMPLATE_INVALID,
  SETTINGS_TEMPLATE_INVALID_NOTE,
  SETTINGS_TEMPLATE_UNREADABLE,
  secretsHelp,
  secretsHelpRefused,
  templateFindingLine,
} from "@/lib/copy-customize";
import { secretEditIn, secretsIn, withoutSecretEdit } from "@/lib/secret-rows";
import { editIn, skillIn } from "@/lib/settings-rows";

/**
 * One skill's own settings at the place being edited: the keys its
 * template declares, where this project's `kendex.settings.toml` stands on
 * each, and the credentials it declares separately.
 *
 * A skill that declares neither gets no section rather than an empty one.
 * Every other state gets a section that says what it is: a template out of
 * reach, and a template the strict reader refuses, are answers about the
 * template and say nothing about what the files hold, because seeding is
 * lenient and may have written those keys anyway.
 *
 * The two kinds of key never share a section. They are written to
 * different files under different rules — one tracked, one private — and a
 * person about to type a credential has to read where it goes in the
 * section they are typing into.
 */
export function SkillSettings({
  skill,
  settings,
  edits,
  secretEdits,
  pickedFile,
  onEdit,
  onSecretEdit,
  onSecretEdits,
  onPickFile,
}: {
  skill: string;
  /** The place's read, null until it lands or where it failed. */
  settings: ScopeSettings | null;
  edits: SettingsEdit[];
  secretEdits: SecretEdit[];
  /** The private file the person picked here, null while they have not. */
  pickedFile: string | null;
  onEdit: (edit: SettingsEdit) => void;
  onSecretEdit: (edit: SecretEdit) => void;
  onSecretEdits: (next: SecretEdit[]) => void;
  onPickFile: (file: string | null) => void;
}) {
  // A place with no settings file at all is global, where a private file
  // has nowhere to live either. Saying so beats showing nothing: a package
  // installed for everything still needs its key somewhere, and the answer
  // is a project.
  if (settings && !settings.applies) {
    return (
      <Section title={SETTINGS_SECTION}>
        <StatusNote tone="info" title={SECRETS_NEED_A_PROJECT} />
      </Section>
    );
  }
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

  const secrets = secretsIn(mine);
  const secretsView = settings?.secrets ?? null;
  const contested = contestedFor(settings, mine);
  return (
    <>
      {contested.length > 0 ? (
        <Section title={SETTINGS_SECTION}>
          <StatusNote tone="warning" title={CONTESTED_KEYS}>
            <ul className="flex flex-col gap-1">
              {contested.map((one) => (
                <li key={one.key}>{one.problem}</li>
              ))}
            </ul>
          </StatusNote>
        </Section>
      ) : null}
      {template.rows.length > 0 ? (
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
      ) : null}
      {secrets.length > 0 && secretsView ? (
        <Section
          title={SECRETS_SECTION}
          description={
            secretsView.destination.state.state === "refused"
              ? secretsHelpRefused(secretsView.destination.file)
              : secretsHelp(secretsView.destination.file)
          }
        >
          <SecretDestination
            secrets={secretsView}
            picked={pickedFile}
            onPick={onPickFile}
          />
          <div className="flex flex-col divide-y border-t">
            {secrets.map((row) => (
              <SecretFieldRow
                key={row.key}
                skill={skill}
                row={row}
                file={secretsView.destination.file}
                writable={secretsView.destination.state.state !== "refused"}
                edit={secretEditIn(secretEdits, skill, row.key)}
                onEdit={onSecretEdit}
                onCancel={() =>
                  onSecretEdits(withoutSecretEdit(secretEdits, skill, row.key))
                }
              />
            ))}
          </div>
        </Section>
      ) : null}
    </>
  );
}

/** The keys this place's packages disagree about that this skill declares
 *  — the ones whose missing field the person is looking for. */
function contestedFor(
  settings: ScopeSettings | null,
  mine: SkillSettingsRead | null,
) {
  if (!settings || !mine || mine.template.state !== "rows") return [];
  return settings.contested.filter(
    (one) => one.public.includes(mine.skill) || one.secret.includes(mine.skill),
  );
}
