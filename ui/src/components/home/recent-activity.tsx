import type { HarnessId } from "@/bindings";
import { Ago } from "@/components/ago";
import { RECENT_ACTIVITY_EMPTY } from "@/lib/copy";
import { groupRef, type RecentGroup } from "@/lib/derive";
import { kindIcon } from "@/lib/kind-icon";
import { harnessName, hookDisplayName, kindLabel } from "@/lib/labels";
import { useNavStore } from "@/stores/nav";

/** The last things to change on this machine. This is a file's own
 *  timestamp, so what it can honestly report is that the file changed, and
 *  when — not what happened to it. */
export function RecentActivity({ groups }: { groups: RecentGroup[] }) {
  const goToPackage = useNavStore((s) => s.goToPackage);

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
        // The row names one package, so it opens that package — at the
        // place whose copy the time beside it is the time of. The group's
        // stamp is the newest of its installations, so opening the first
        // one would show a reader files that did not change when the row
        // says they did. It opens on the group's own identity, so a
        // recorded package and a stranger under its name stay two rows
        // that open two pages.
        const changed =
          group.installations.find(
            (one) => one.modifiedAt === group.modifiedAt,
          ) ?? group.installations[0];
        const where = changed?.scope;
        return (
          <button
            key={group.key}
            type="button"
            className="-mx-2 flex w-full items-center gap-3 rounded-md px-2 py-2 text-left transition-colors hover:bg-accent"
            onClick={() =>
              where && goToPackage({ ...groupRef(group), scope: where })
            }
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
