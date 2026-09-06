import { useEffect, useRef, useState } from "react";
import {
  commands,
  type HarnessId,
  type InstallTarget,
  type ItemKind,
  type PackageDependencies,
  type Scope,
} from "@/bindings";
import { DependencyChoice } from "@/components/marketplaces/package-dependencies";
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

/** What the picker settled — every answer it takes, in one value the
 * install sends as a whole. `harnesses` and `method` start `null`, meaning
 * "leave it to the scope's own defaults": the state before anyone touched
 * the picker, and the only state in which the install sends neither. The
 * optional dependencies start empty, which is a settled answer rather than
 * an absent one — an extra nobody ticked is not installed. */
export type Choice = {
  harnesses: HarnessId[] | null;
  method: Delivery | null;
  optional: string[];
};

/** Whether this choice can be installed. An empty tool list is a choice to
 * install nowhere, which would report success over a plan that wrote
 * nothing; the untouched picker is not that — it is no choice at all.
 *
 * The list this reads holds only tools the picker offers: `HarnessSelect`
 * reconciles it against every answer it gets, so a choice narrowed to
 * nothing arrives here as an empty list rather than as tools no row shows.
 * That is what makes this gate and the trigger's label one answer. */
export function isInstallable(choice: Choice): boolean {
  return choice.harnesses === null || choice.harnesses.length > 0;
}

/** Where an install lands: the shared `.agents` home is always part of it,
 * the tools on this machine come pre-checked, every tool kendex can install
 * to is offerable, and the delivery is picked alongside. The same choice
 * the CLI's picker puts at a terminal. A package that declares
 * dependencies says so here too, beside the button that acts on it: what
 * comes with it whatever anyone does, and a box per optional extra. */
export function HarnessSelect({
  scope,
  kinds,
  dependencies,
  value,
  onChange,
}: {
  scope: Scope;
  /** The kinds this install would declare. Only tools that can take one of
   * them are offered — the same filter the install itself refuses by. */
  kinds: ItemKind[];
  /** What the package being installed declares it needs, when the caller
   * is installing one package. A whole set carries its members' own
   * declarations and names none of them here. */
  dependencies?: PackageDependencies | null;
  value: Choice;
  onChange: (choice: Choice) => void;
}) {
  const [targets, setTargets] = useState<InstallTarget[]>([]);
  // The read's dependency is the kinds as one value, because the array
  // itself is fresh on every render. Splitting that key back is where the
  // emptiness has to survive: `"".split(",")` is one blank kind, which
  // `ItemKind` has no variant for, so the command refuses the whole call
  // and the picker is left with no row to tick. Naming no kind is what an
  // empty key means, and the command reads that as every kind.
  const wanted = kinds.join(",");
  // The choice as it stands when an answer lands, which is not the one the
  // read was started under: the reconciliation below runs in the answer's
  // own callback so the rows and the choice reconciled against them reach
  // the screen in one paint, and it cannot take either as a dependency
  // without asking the command again on every tick.
  const latest = useRef({ value, onChange });
  useEffect(() => {
    latest.current = { value, onChange };
  });

  useEffect(() => {
    let live = true;
    const asked = wanted === "" ? [] : (wanted.split(",") as ItemKind[]);
    void commands.installTargets(scope, asked).then((r) => {
      if (!live || r.status !== "ok") return;
      setTargets(r.data);
      // The one place the choice is reconciled against what is offered.
      // A choice made against a wider set of kinds can name a tool this
      // answer no longer offers; the display drops it either way, and
      // dropping it from the choice too is what keeps the install gate
      // reading the same answer the trigger shows. Left in, a narrowing
      // that empties the picker leaves every Install button pressable
      // over a plan that would write nothing.
      const choice = latest.current.value;
      if (choice.harnesses === null) return;
      const offers = new Set(r.data.map((t) => t.harness));
      const kept = choice.harnesses.filter((one) => offers.has(one));
      if (kept.length !== choice.harnesses.length)
        latest.current.onChange({ ...choice, harnesses: kept });
    });
    return () => {
      live = false;
    };
  }, [scope, wanted]);

  // Untouched, the picker shows what this machine has and sends nothing:
  // detection is re-read at install time, so the engine's own answer and
  // the one drawn here are the same answer, taken a moment apart. A tool
  // this destination cannot install to is dropped from the display — the
  // rows come from the same filter the install refuses by, so a selection
  // made before the destination changed cannot survive as a row. The
  // filter still stands over the window before the first answer lands,
  // where there is nothing yet to reconcile the choice against.
  const offered = new Set(targets.map((t) => t.harness));
  const detected = targets.filter((t) => t.detected).map((t) => t.harness);
  const chosen = (value.harnesses ?? detected).filter((held) =>
    offered.has(held),
  );
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
        {dependencies &&
        dependencies.required.length + dependencies.optional.length > 0 ? (
          <DependencyChoice
            dependencies={dependencies}
            chosen={value.optional}
            onChange={(optional) => onChange({ ...value, optional })}
          />
        ) : null}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
