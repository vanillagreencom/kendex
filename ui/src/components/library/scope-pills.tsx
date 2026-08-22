import type { Scope } from "@/bindings";
import { Pill } from "@/components/pill";
import type { ScopeSelection } from "@/lib/derive";
import { scopeName } from "@/lib/labels";

/** Where the table is looking. The Library's own location filter — no other
 *  page narrows by location, they state it on each row — and a link into the
 *  Library can name one on the way in. */
export function ScopePills({
  scope,
  onScopeChange,
  projects,
}: {
  scope: ScopeSelection;
  onScopeChange: (scope: ScopeSelection) => void;
  /** Project roots to offer: the ones holding something, and the one being
   * looked at. */
  projects: string[];
}) {
  const among = projects.map((root): Scope => ({ scope: "project", root }));
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
      <div className="flex flex-wrap gap-1.5">
        <Pill selected={scope === "all"} onClick={() => onScopeChange("all")}>
          Everywhere
        </Pill>
        <Pill
          selected={scope === "global"}
          onClick={() => onScopeChange("global")}
        >
          Personal
        </Pill>
        {projects.map((root) => (
          <Pill
            key={root}
            title={root}
            selected={
              scope !== "all" && scope !== "global" && scope.project === root
            }
            onClick={() => onScopeChange({ project: root })}
          >
            {scopeName({ scope: "project", root }, among)}
          </Pill>
        ))}
      </div>
    </div>
  );
}
