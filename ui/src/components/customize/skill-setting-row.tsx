import { useId } from "react";
import type { SettingsEdit, SettingsRow } from "@/bindings";
import { SettingRow } from "@/components/section";
import { StatusLine } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  SETTINGS_RESET,
  settingAmbiguous,
  settingDiffers,
} from "@/lib/copy-customize";
import { differsFromDefault, effectiveValue } from "@/lib/settings-rows";

/**
 * One key a skill declares: what the author says it is for, what this
 * project's file says it is, and the two ways to change that.
 *
 * The default is the input's placeholder rather than its value, so a key
 * nothing assigns reads as "this is what you get" instead of as a value
 * somebody chose. Where the file does answer and the answer is not the
 * default, the row says so as a fact about the file — the value may have
 * been seeded, imported or hand-written, and nothing here knows which.
 */
export function SkillSettingRow({
  skill,
  row,
  edit,
  onEdit,
}: {
  skill: string;
  row: SettingsRow;
  /** This row's unsaved answer, where one has been given. */
  edit?: SettingsEdit;
  onEdit: (edit: SettingsEdit) => void;
}) {
  const id = useId();
  const explainer = row.explainer.join(" ").trim();
  const key = <code className="font-mono text-[13px]">{row.key}</code>;

  // Nothing here can write a key the file answers for in a shape no
  // script reads: core refuses the edit, so the row offers no control
  // and names the lines to settle it on instead.
  if (row.current.state === "ambiguous") {
    const { problem, lines } = row.current;
    // The note sits beside the row rather than inside its description:
    // a description renders as a paragraph, and a status line is one too.
    return (
      <div role="status" className="py-3.5 first:pt-0">
        <SettingRow label={key} description={explainer} className="py-0" />
        <StatusLine tone="warning" className="mt-1">
          {settingAmbiguous(row.key, problem, lines)}
        </StatusLine>
      </div>
    );
  }

  const value = effectiveValue(row, edit);
  const differs = differsFromDefault(row, edit);
  return (
    <SettingRow
      htmlFor={id}
      label={key}
      description={
        <>
          {explainer}
          {differs ? (
            <span className="mt-1 block">{settingDiffers(row.default)}</span>
          ) : null}
        </>
      }
    >
      <Input
        id={id}
        className="w-64"
        placeholder={row.default}
        value={value ?? ""}
        onChange={(event) =>
          onEdit({
            skill,
            key: row.key,
            value: { kind: "set", value: event.target.value },
          })
        }
      />
      {differs ? (
        <Button
          variant="ghost"
          size="sm"
          onClick={() =>
            onEdit({ skill, key: row.key, value: { kind: "reset" } })
          }
        >
          {SETTINGS_RESET}
        </Button>
      ) : null}
    </SettingRow>
  );
}
