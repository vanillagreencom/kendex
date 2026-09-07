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
 * A tool list here names only tools the picker's last answer offered:
 * `HarnessSelect` narrows the reader's pick to that answer before handing
 * it back, so a pick the answer holds nothing of arrives as an empty list
 * rather than as tools no row shows. That is what makes this gate and the
 * trigger's label one answer about a chosen list. The untouched picker is
 * the state neither of them is about. */
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
  const asking = kinds.join(",");
  // The choice as it stands when an answer lands, which is not the one the
  // read was started under: the narrowing below runs in the answer's own
  // callback so the rows and the choice narrowed to them reach the screen
  // in one paint, and it cannot take either as a dependency without asking
  // the command again on every tick.
  const latest = useRef({ value, onChange });
  // What the reader actually picked, kept apart from the narrowed list the
  // install is sent. Which tools are offered is a fact about the kinds
  // being installed, and those change while the page is open — so the pick
  // is answered against each new set rather than overwritten by the first
  // one to narrow it, and a tool a narrowing hid comes back when the set
  // widens again instead of being dropped from the install unremarked.
  const wanted = useRef<HarnessId[] | null>(null);
  useEffect(() => {
    latest.current = { value, onChange };
    // Put back to no choice at all — what a destination change does — and
    // the pick goes with it: it was an answer about the place before.
    if (value.harnesses === null) wanted.current = null;
  });

  useEffect(() => {
    let live = true;
    const asked = asking === "" ? [] : (asking.split(",") as ItemKind[]);
    void commands.installTargets(scope, asked).then((r) => {
      if (!live || r.status !== "ok") return;
      setTargets(r.data);
      // The one place a pick is answered against what is offered, so the
      // install gate and the trigger's label read one list. A pick made
      // against a wider set of kinds can name a tool this answer no longer
      // offers; left in, a narrowing that holds none of the picked tools
      // leaves every Install button pressable over a trigger reading "No
      // tools" and a plan that would write nothing.
      const choice = latest.current.value;
      const picked = wanted.current;
      if (picked === null || choice.harnesses === null) return;
      const offers = new Set(r.data.map((t) => t.harness));
      const kept = picked.filter((one) => offers.has(one));
      if (kept.join(",") !== choice.harnesses.join(","))
        latest.current.onChange({ ...choice, harnesses: kept });
    });
    return () => {
      live = false;
    };
  }, [scope, asking]);

  // Untouched, the picker shows what this machine has and sends nothing:
  // detection is re-read at install time, so the engine's own answer and
  // the one drawn here are the same answer, taken a moment apart. Both
  // lists come from the answer in hand — detection is a column of it, and
  // a picked list was narrowed to it above — so a tool this destination
  // cannot install to has no row here and is in neither.
  const detected = targets.filter((t) => t.detected).map((t) => t.harness);
  const chosen = value.harnesses ?? detected;
  // Every pick goes through here: it is the reader's answer, kept as such,
  // and the list the install is sent is that answer narrowed to what the
  // destination offers.
  const pick = (harnesses: HarnessId[]) => {
    wanted.current = harnesses;
    onChange({ ...value, harnesses });
  };
  const toggle = (harness: HarnessId) =>
    pick(
      chosen.includes(harness)
        ? chosen.filter((held) => held !== harness)
        : [...chosen, harness],
    );
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
            onClick={() => pick(targets.map((t) => t.harness))}
          >
            All tools
          </Button>
          <Button variant="outline" size="sm" onClick={() => pick(detected)}>
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
