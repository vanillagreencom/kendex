import type { SettingsEdit, SettingsRow } from "@/bindings";
import { StatusLine } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  SETTINGS_DEFAULT_EMPTY,
  SETTINGS_RESET,
  settingAmbiguous,
  settingDiffers,
} from "@/lib/copy-customize";
import { differsFromDefault, effectiveValue } from "@/lib/settings-rows";

/**
 * One key a skill declares: what the author says it is for, what this
 * project's file says it is, and the two ways to change that.
 *
 * The row splits down the middle rather than borrowing the app's shared
 * setting lane. That lane is sized for a switch or a dropdown; these keys
 * hold path globs and space-separated lists, and a value a person has to
 * scrub sideways to read is worse than a narrower explainer beside it.
 *
 * The default is the input's placeholder rather than its value, so a key
 * nothing assigns reads as "this is what you get" instead of as a value
 * somebody chose. A default that is itself empty says so in words — one
 * phrase for every such key, because the explainer beside it is the
 * author's free text and mining it would invent copy nobody wrote. Where
 * the file does answer and the answer is not the default, the row says so
 * as a fact about the file: the value may have been seeded, imported or
 * hand-written, and nothing here knows which.
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
  // Nothing here can write a key the file answers for in a shape no
  // script reads: core refuses the edit, so the row offers no control
  // and names the lines to settle it on instead.
  const ambiguous = row.current.state === "ambiguous" ? row.current : null;
  const differs = !ambiguous && differsFromDefault(row, edit);

  return (
    <div
      role={ambiguous ? "status" : undefined}
      className="flex items-start gap-8 py-3.5 first:pt-0"
    >
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <span className="text-sm font-medium">
          <code className="font-mono text-[13px]">{row.key}</code>
        </span>
        <p className="max-w-prose text-[13px] leading-relaxed text-muted-foreground">
          {row.explainer.join(" ").trim()}
          {differs ? (
            <span className="mt-1 block">{settingDiffers(row.default)}</span>
          ) : null}
        </p>
        {ambiguous ? (
          <StatusLine tone="warning">
            {settingAmbiguous(row.key, ambiguous.problem, ambiguous.lines)}
          </StatusLine>
        ) : null}
      </div>
      {ambiguous ? null : (
        // Half the row, and the same half whether or not Reset is
        // showing: an input that narrows the moment its value leaves the
        // default would shrink on the row a person is most likely
        // reading. The explainer takes what is left.
        <div className="flex w-1/2 shrink-0 flex-col items-end gap-2 pt-0.5">
          <Input
            aria-label={row.key}
            className="w-full"
            placeholder={
              row.default === "" ? SETTINGS_DEFAULT_EMPTY : row.default
            }
            value={effectiveValue(row, edit) ?? ""}
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
        </div>
      )}
    </div>
  );
}
