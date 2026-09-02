import type { Scope } from "@/bindings";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { scopeLabel } from "@/lib/derive";
import { scopeName } from "@/lib/labels";
import { everyPlace } from "@/lib/scope";
import { useSettingsStore } from "@/stores/settings";

// Settings arrive after the first render, and the no-settings answer is
// read through a store selector: a fresh array each call is a new
// reference every render, which is a render loop rather than an empty
// list. One shared value instead.
const NO_PROJECTS: string[] = [];

/** Where an install lands. Browsing a personal subscription may redirect
 * into a project (the project gains the subscription in the same step);
 * a project subscription installs into its own project, so the picker
 * only opens up when there is a real choice. */
export function DestinationSelect({
  browsing,
  value,
  onChange,
}: {
  browsing: Scope;
  value: Scope;
  onChange: (scope: Scope) => void;
}) {
  const projects = useSettingsStore((s) => s.settings?.projects ?? NO_PROJECTS);
  const options: Scope[] =
    browsing.scope === "global" ? everyPlace(projects) : [browsing];

  return (
    <Select
      value={scopeLabel(value)}
      onValueChange={(label) => {
        const target = options.find((s) => scopeLabel(s) === label);
        if (target) onChange(target);
      }}
    >
      <SelectTrigger size="sm" className="w-auto gap-1.5">
        <span className="text-muted-foreground">Install to</span>
        <SelectValue>
          {(current: string) => {
            const scope = options.find((s) => scopeLabel(s) === current);
            return scope ? scopeName(scope) : current;
          }}
        </SelectValue>
      </SelectTrigger>
      <SelectContent>
        {options.map((scope) => (
          <SelectItem key={scopeLabel(scope)} value={scopeLabel(scope)}>
            {scopeName(scope)}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}
