import type { HarnessId } from "@/bindings";
import { Ago } from "@/components/ago";
import { RECENT_ACTIVITY_EMPTY } from "@/lib/copy";
import type { RecentGroup } from "@/lib/derive";
import { kindIcon } from "@/lib/kind-icon";
import { harnessName, hookDisplayName, kindLabel } from "@/lib/labels";
import { useNavStore } from "@/stores/nav";

/** The last things to change on this machine. "Activity" said nothing about
 *  what happened; this is a file's own timestamp, so what it can honestly
 *  report is that the file changed, and when. */
export function RecentActivity({ groups }: { groups: RecentGroup[] }) {
  const goToLibrary = useNavStore((s) => s.goToLibrary);

  if (groups.length === 0) {
    return (
      <p className="text-sm text-muted-foreground">{RECENT_ACTIVITY_EMPTY}</p>
    );
  }

  return (
    <div className="flex flex-col">
      {groups.map((group) => {
        const Icon = kindIcon(group.kind);
        const name =
          group.kind === "hook" ? hookDisplayName(group.name) : group.name;
        const tools = group.harnesses
          .map((h) => harnessName(h as HarnessId))
          .join(", ");
        return (
          <button
            key={group.key}
            type="button"
            className="-mx-2 flex w-full items-center gap-3 rounded-md px-2 py-2 text-left transition-colors hover:bg-accent"
            onClick={() => goToLibrary({ kind: group.kind })}
          >
            <Icon className="size-4 shrink-0 text-muted-foreground" />
            <span className="min-w-0 flex-1 truncate font-medium">{name}</span>
            <span className="hidden shrink-0 truncate text-xs text-muted-foreground sm:inline">
              {kindLabel(group.kind)} · {tools}
            </span>
            <Ago
              at={group.modifiedAt * 1000}
              className="shrink-0 text-xs text-muted-foreground"
            />
          </button>
        );
      })}
    </div>
  );
}
