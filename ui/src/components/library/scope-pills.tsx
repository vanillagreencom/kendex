import { Pill } from "@/components/pill";
import type { ScopeSelection } from "@/lib/derive";
import { scopeName } from "@/lib/labels";

/** Where the table is looking: the same app-wide scope the sidebar sets, so
 *  the two can never disagree about which project is on screen. */
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
            {scopeName({ scope: "project", root })}
          </Pill>
        ))}
      </div>
    </div>
  );
}
