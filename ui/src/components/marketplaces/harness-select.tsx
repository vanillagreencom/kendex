import { useEffect, useState } from "react";
import {
  commands,
  type HarnessId,
  type InstallTarget,
  type Scope,
} from "@/bindings";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Label } from "@/components/ui/label";
import { harnessName } from "@/lib/labels";

export type Delivery = "symlink" | "copy";

/** What the picker settled. Both halves start `null`, meaning "leave it to
 * the scope's own defaults" — the state before anyone touched the picker,
 * and the only state in which the install sends neither. */
export type Choice = {
  harnesses: HarnessId[] | null;
  method: Delivery | null;
};

/** Whether this choice can be installed. An empty tool list is a choice to
 * install nowhere, which would report success over a plan that wrote
 * nothing; the untouched picker is not that — it is no choice at all. */
export function isInstallable(choice: Choice): boolean {
  return choice.harnesses === null || choice.harnesses.length > 0;
}

/** Where an install lands: the shared `.agents` home is always part of it,
 * the tools on this machine come pre-checked, every tool kendex can install
 * to is offerable, and the delivery is picked alongside. The same choice
 * the CLI's picker puts at a terminal. */
export function HarnessSelect({
  scope,
  value,
  onChange,
}: {
  scope: Scope;
  value: Choice;
  onChange: (choice: Choice) => void;
}) {
  const [targets, setTargets] = useState<InstallTarget[]>([]);

  useEffect(() => {
    let live = true;
    void commands.installTargets(scope).then((r) => {
      if (live && r.status === "ok") setTargets(r.data);
    });
    return () => {
      live = false;
    };
  }, [scope]);

  // Untouched, the picker shows what this machine has and sends nothing:
  // detection is re-read at install time, so the engine's own answer and
  // the one drawn here are the same answer, taken a moment apart.
  const detected = targets.filter((t) => t.detected).map((t) => t.harness);
  const chosen = value.harnesses ?? detected;
  const toggle = (harness: HarnessId) =>
    onChange({
      ...value,
      harnesses: chosen.includes(harness)
        ? chosen.filter((held) => held !== harness)
        : [...chosen, harness],
    });
  const label =
    chosen.length === 0
      ? "No tools — pick at least one"
      : chosen.length === targets.length
        ? "All tools"
        : chosen.length === 1
          ? harnessName(chosen[0])
          : `${chosen.length} tools`;

  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button variant="outline" size="sm" className="gap-1.5">
            <span className="text-muted-foreground">Install for</span>
            {label}
          </Button>
        }
      />
      <DropdownMenuContent align="end" className="w-72 p-3">
        <p className="pb-2 text-xs text-muted-foreground">
          The shared <code>.agents</code> home is always included. Every tool
          below reads it or gets its own delivery.
        </p>
        <div className="flex flex-col gap-2">
          {targets.map((target) => (
            <Label
              key={target.harness}
              className="flex items-center gap-2 font-normal"
            >
              <Checkbox
                checked={chosen.includes(target.harness)}
                onCheckedChange={() => toggle(target.harness)}
              />
              {harnessName(target.harness)}
              {target.detected ? (
                <span className="text-xs text-muted-foreground">
                  on this machine
                </span>
              ) : null}
            </Label>
          ))}
        </div>
        <div className="mt-3 flex gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={() =>
              onChange({
                ...value,
                harnesses: targets.map((t) => t.harness),
              })
            }
          >
            All tools
          </Button>
          <Button
            variant="outline"
            size="sm"
            onClick={() =>
              onChange({
                ...value,
                harnesses: detected,
              })
            }
          >
            Just what I have
          </Button>
        </div>
        <div className="mt-3 border-t pt-3">
          <p className="pb-2 text-xs text-muted-foreground">Delivery</p>
          <div className="flex flex-col gap-2">
            <Label className="flex items-center gap-2 font-normal">
              <Checkbox
                checked={(value.method ?? "symlink") === "symlink"}
                onCheckedChange={() =>
                  onChange({ ...value, method: "symlink" })
                }
              />
              Symlink — one shared copy every tool reads
            </Label>
            <Label className="flex items-center gap-2 font-normal">
              <Checkbox
                checked={value.method === "copy"}
                onCheckedChange={() => onChange({ ...value, method: "copy" })}
              />
              Copy — a real tree per tool
            </Label>
          </div>
        </div>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
