import { Plus, X } from "lucide-react";
import type { EditorInventory, HookDelivery, Scope } from "@/bindings";
import { CommitInput, Field } from "@/components/customize/controls";
import { EventPicker } from "@/components/customize/event-picker";
import { HarnessChoice } from "@/components/customize/harness-choice";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Switch } from "@/components/ui/switch";
import {
  HOOK_AGENTS_LABEL,
  HOOK_COMMAND_HELP,
  HOOK_COMMAND_PLACEHOLDER,
  HOOK_DISABLED_NOTE,
  HOOK_HARNESSES_LABEL,
  HOOK_NAME_LABEL,
  HOOK_NAME_PLACEHOLDER,
  HOOK_ON_LABEL,
  HOOK_TIMEOUT_LABEL,
  hookDeliverySummary,
  MATCHER_HELP,
} from "@/lib/copy-customize";
import {
  addCustomHook,
  type Draft,
  type DraftHook,
  formatHookAgents,
  parseHookAgents,
  removeCustomHook,
  setCustomHook,
} from "@/lib/editor-draft";
import { useHookDeliveries } from "@/lib/hook-deliveries";

export function CustomHooks({
  draft,
  inventory,
  scope,
  onChange,
}: {
  draft: Draft;
  inventory: EditorInventory | null;
  scope: Scope;
  onChange: (change: (draft: Draft) => Draft) => void;
}) {
  const hooks = draft["custom-hooks"] ?? [];
  const deliveries = useHookDeliveries(scope, hooks);

  return (
    <div className="flex flex-col gap-3">
      {hooks.map((hook, index) => (
        <HookCard
          // biome-ignore lint/suspicious/noArrayIndexKey: unsaved hooks have no name yet; position is the draft's identity
          key={index}
          hook={hook}
          inventory={inventory}
          deliveries={deliveries[index] ?? []}
          onEdit={(next) =>
            onChange((current) => setCustomHook(current, index, next))
          }
          onRemove={() =>
            onChange((current) => removeCustomHook(current, index))
          }
        />
      ))}
      <div>
        <Button
          variant="outline"
          size="sm"
          onClick={() => onChange((current) => addCustomHook(current))}
        >
          <Plus className="size-4" />
          Add hook
        </Button>
      </div>
    </div>
  );
}

function HookCard({
  hook,
  inventory,
  deliveries,
  onEdit,
  onRemove,
}: {
  hook: DraftHook;
  inventory: EditorInventory | null;
  deliveries: HookDelivery[];
  onEdit: (hook: DraftHook) => void;
  onRemove: () => void;
}) {
  const optional = (text: string) => (text === "" ? null : text);
  const enabled = hook.enabled ?? true;
  const ready = hook.event !== "" && hook.command !== "";
  const summary = ready ? hookDeliverySummary(deliveries) : "";

  return (
    <Card>
      <CardContent className="grid gap-3 sm:grid-cols-2">
        <Field label={HOOK_NAME_LABEL}>
          <Input
            aria-label="Name"
            placeholder={HOOK_NAME_PLACEHOLDER}
            value={hook.name ?? ""}
            onChange={(e) =>
              onEdit({ ...hook, name: optional(e.target.value) })
            }
          />
        </Field>
        <Field label="Event">
          <EventPicker
            value={hook.event}
            events={inventory?.hookEvents ?? []}
            onPick={(event) => onEdit({ ...hook, event })}
          />
        </Field>
        <Field label={MATCHER_HELP}>
          <Input
            aria-label="Matcher"
            placeholder="Bash"
            value={hook.matcher ?? ""}
            onChange={(e) =>
              onEdit({ ...hook, matcher: optional(e.target.value) })
            }
          />
        </Field>
        <Field label={HOOK_COMMAND_HELP}>
          <Input
            aria-label="Command"
            placeholder={HOOK_COMMAND_PLACEHOLDER}
            value={hook.command}
            onChange={(e) => onEdit({ ...hook, command: e.target.value })}
          />
        </Field>
        <Field label={HOOK_AGENTS_LABEL}>
          <CommitInput
            label="Agents"
            placeholder="all"
            value={formatHookAgents(hook.agents)}
            onCommit={(text) =>
              onEdit({ ...hook, agents: parseHookAgents(text) })
            }
          />
        </Field>
        <Field label={HOOK_TIMEOUT_LABEL}>
          <Input
            aria-label="Timeout"
            type="number"
            min={1}
            max={3600}
            value={hook.timeout ?? ""}
            onChange={(e) =>
              onEdit({
                ...hook,
                timeout: e.target.value === "" ? null : Number(e.target.value),
              })
            }
          />
        </Field>
        <Field label="Description (optional)">
          <Input
            aria-label="Description"
            value={hook.description ?? ""}
            onChange={(e) =>
              onEdit({ ...hook, description: optional(e.target.value) })
            }
          />
        </Field>
        <Field label={HOOK_HARNESSES_LABEL}>
          <HarnessChoice
            all={inventory?.harnesses ?? []}
            chosen={hook.harnesses ?? null}
            onChoose={(harnesses) => onEdit({ ...hook, harnesses })}
          />
        </Field>
        <div className="flex items-center justify-between sm:col-span-2">
          <span className="text-[13px] text-muted-foreground">
            {enabled ? summary : HOOK_DISABLED_NOTE}
          </span>
          <span className="flex items-center gap-2">
            <Switch
              aria-label={HOOK_ON_LABEL}
              checked={enabled}
              onCheckedChange={(on) => onEdit({ ...hook, enabled: on })}
            />
            <Button
              variant="ghost"
              size="sm"
              aria-label="Remove hook"
              onClick={onRemove}
            >
              <X className="size-4" />
              Remove
            </Button>
          </span>
        </div>
      </CardContent>
    </Card>
  );
}
