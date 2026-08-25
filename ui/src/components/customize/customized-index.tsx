import { ChevronRight } from "lucide-react";
import type { ItemKind, Scope } from "@/bindings";
import { Button } from "@/components/ui/button";
import {
  CUSTOMIZED_UPDATES_UNCHECKED,
  customizedLine,
  NOT_INSTALLED_HERE,
  NOTHING_CUSTOMIZED,
  REMOVE_CUSTOMIZATION,
} from "@/lib/copy-customize";
import { isCustomized } from "@/lib/customization";
import type { CustomizedHere } from "@/lib/customized-places";
import { kindIcon } from "@/lib/kind-icon";
import { kindLabel } from "@/lib/labels";
import { sameScope } from "@/lib/scope";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";

/** Every package customized at this scope: settings, a hand edit, or a
 *  fork. A row opens that package's own page, which is where its edits are
 *  made; a row for something no longer installed has no page to open, so
 *  it offers only to drop the settings, where there are any to drop. */
export function CustomizedIndex({
  items,
  scope,
  updatesFailed,
  onRemove,
}: {
  items: CustomizedHere[];
  scope: Scope;
  /** The update read failed with nothing landed. Hand edits are read from
   *  it, so a package missing here may be missing for that reason, and
   *  the section says so rather than calling the place clean. */
  updatesFailed: boolean;
  onRemove: (kind: ItemKind, name: string) => void;
}) {
  const goToPackage = useNavStore((s) => s.goToPackage);
  // Selects the result, not a fallback array: a fresh `[]` from a selector
  // is a new snapshot every render, and React re-renders until it is not.
  const installed = useScanStore((s) => s.result)?.items ?? [];

  const unchecked = updatesFailed ? (
    <p className="pt-1 text-sm text-muted-foreground">
      {CUSTOMIZED_UPDATES_UNCHECKED}
    </p>
  ) : null;

  if (items.length === 0) {
    return (
      unchecked ?? (
        <p className="pt-1 text-sm text-muted-foreground">
          {NOTHING_CUSTOMIZED}
        </p>
      )
    );
  }

  return (
    <div className="flex flex-col divide-y">
      {items.map(({ kind, name, edited, forked, customization }) => {
        const Icon = kindIcon(kind);
        // Installed *here*: a row that opened a page for another scope's
        // copy would show version and files that belong to somewhere else.
        const here = installed.some(
          (item) =>
            item.kind === kind &&
            item.name === name &&
            sameScope(item.scope, scope),
        );
        return (
          <div key={`${kind}:${name}`} className="flex items-center gap-3 py-3">
            <Icon className="size-4 shrink-0 text-customized" />
            <div className="min-w-0 flex-1">
              <p className="truncate text-sm font-medium">{name}</p>
              <p className="truncate text-[13px] text-muted-foreground">
                {kindLabel(kind)} ·{" "}
                {customizedLine({ edited, forked }, customization)}
              </p>
            </div>
            {here ? (
              <Button
                variant="ghost"
                size="sm"
                onClick={() => goToPackage({ kind, name, scope })}
              >
                Open
                <ChevronRight className="size-4" />
              </Button>
            ) : (
              <>
                <span className="text-[13px] text-muted-foreground">
                  {NOT_INSTALLED_HERE}
                </span>
                {isCustomized(customization) ? (
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => onRemove(kind, name)}
                  >
                    {REMOVE_CUSTOMIZATION}
                  </Button>
                ) : null}
              </>
            )}
          </div>
        );
      })}
      {unchecked}
    </div>
  );
}
