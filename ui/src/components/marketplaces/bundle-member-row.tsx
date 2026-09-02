import type { BundleMemberRow } from "@/bindings";
import { StatusDot } from "@/components/status-dot";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { PACKAGE_STATE_UNKNOWN } from "@/lib/copy-marketplaces";
import { offersInstall } from "@/lib/install-state";
import { kindIcon } from "@/lib/kind-icon";
import { kindLabel, packageDisplayName } from "@/lib/labels";
import { cn } from "@/lib/utils";

export const memberKey = (kind: string, name: string) => `${kind}:${name}`;

/** One member of a curated set: its state here, and — where the set comes
 * from a subscription — a box to pick it for install. */
export function BundleMemberLine({
  member,
  selectable,
  selected,
  busy,
  onToggle,
  onRestore,
}: {
  member: BundleMemberRow;
  /** False while the set is browsed from a repository nobody subscribes to. */
  selectable: boolean;
  selected: boolean;
  busy: boolean;
  onToggle: () => void;
  onRestore: () => void;
}) {
  const Icon = kindIcon(member.kind);
  const installable = selectable && offersInstall(member.state);
  const id = `member-${memberKey(member.kind, member.name)}`;
  return (
    <label
      htmlFor={id}
      className={cn(
        "flex items-center gap-3 px-4 py-2.5",
        installable ? "cursor-pointer" : "opacity-80",
      )}
    >
      {selectable ? (
        <Checkbox
          id={id}
          checked={selected}
          disabled={!installable}
          onCheckedChange={onToggle}
        />
      ) : null}
      <Icon className="size-4 shrink-0 text-muted-foreground" />
      <span className="min-w-0 flex-1 truncate font-medium">
        {packageDisplayName(member)}
      </span>
      <span className="w-24 text-xs text-muted-foreground">
        {kindLabel(member.kind)}
      </span>
      <span className="w-32 text-right text-xs">
        {member.state === "installed" ? (
          <span className="text-muted-foreground">Installed</span>
        ) : member.state === "not-offered" ? (
          <span className="text-muted-foreground">No longer offered</span>
        ) : member.state === "removed-by-you" ? (
          <span className="inline-flex items-center gap-2">
            <span className="text-muted-foreground">Removed by you</span>
            <Button
              size="sm"
              variant="outline"
              disabled={busy}
              onClick={(e) => {
                e.preventDefault();
                onRestore();
              }}
            >
              Restore
            </Button>
          </span>
        ) : member.state === "unknown" ? (
          <span className="text-muted-foreground">{PACKAGE_STATE_UNKNOWN}</span>
        ) : (
          <StatusDot tone="good" className="inline-block" title="Available" />
        )}
      </span>
    </label>
  );
}
