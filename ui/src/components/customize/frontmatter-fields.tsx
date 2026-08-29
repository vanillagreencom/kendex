import {
  CommitInput,
  Field,
  TriStateSelect,
} from "@/components/customize/controls";
import { Input } from "@/components/ui/input";
import {
  type DraftFrontmatter,
  formatList,
  parseList,
} from "@/lib/editor-draft";

// The manifest key is what a hand-written kendex.toml uses; the label is
// what a reader sees. A list field says what a list looks like in its
// placeholder rather than in a parenthesis after its name — an example,
// never a value, which is why a field holding one says so on its label.
const TEXT_FIELDS = [
  ["model", "Model", "opus"],
  ["effort", "Effort", "high"],
  ["color", "Color", "blue"],
  ["mode", "Mode", "plan"],
  ["memory", "Memory", "project"],
  ["isolation", "Isolation", "worktree"],
  ["sandbox-mode", "Sandbox", "workspace-write"],
  ["model-reasoning-effort", "Reasoning effort", "medium"],
] as const;

const LIST_FIELDS = [
  ["deny-tools", "Blocked tools", "Bash, WebFetch"],
  ["allow-tools", "Allowed tools", "Read, Edit"],
  ["allowed-subagents", "Allowed subagents", "reviewer, planner"],
  ["nickname-candidates", "Nicknames", "orch, boss"],
] as const;

const FLAG_FIELDS = [
  ["pane", "Own pane"],
  ["background", "Runs in the background"],
] as const;

export type SetField = <K extends keyof DraftFrontmatter>(
  field: K,
  value: DraftFrontmatter[K],
) => void;

/** Empty means unset: a blank field is left out of the manifest entirely. */
export function FrontmatterFields({
  overrides,
  onSet,
}: {
  overrides: DraftFrontmatter;
  onSet: SetField;
}) {
  return (
    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      {TEXT_FIELDS.map(([field, label, placeholder]) => (
        <Field key={field} label={label} set={overrides[field] != null}>
          <Input
            aria-label={label}
            placeholder={placeholder}
            value={overrides[field] ?? ""}
            onChange={(event) =>
              onSet(
                field,
                event.target.value === "" ? null : event.target.value,
              )
            }
          />
        </Field>
      ))}
      {LIST_FIELDS.map(([field, label, placeholder]) => (
        <Field key={field} label={label} set={overrides[field] != null}>
          <CommitInput
            label={label}
            placeholder={placeholder}
            value={formatList(overrides[field])}
            onCommit={(text) => onSet(field, parseList(text))}
          />
        </Field>
      ))}
      {FLAG_FIELDS.map(([field, label]) => (
        <Field key={field} label={label} set={overrides[field] != null}>
          <TriStateSelect
            label={label}
            value={overrides[field]}
            onChange={(value) => onSet(field, value)}
          />
        </Field>
      ))}
    </div>
  );
}
