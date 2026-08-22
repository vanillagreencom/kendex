import { ChevronRight } from "lucide-react";
import type { ItemKind, Scope } from "@/bindings";
import { Button } from "@/components/ui/button";
import {
  customizationSummary,
  NOT_INSTALLED_HERE,
  NOTHING_CUSTOMIZED,
  REMOVE_CUSTOMIZATION,
} from "@/lib/copy-customize";
import type { CustomizedItem } from "@/lib/customization";
import { kindIcon } from "@/lib/kind-icon";
import { kindLabel } from "@/lib/labels";
import { customizeNav } from "@/lib/place-marks";
import { sameScope } from "@/lib/scope";
import { useNavStore } from "@/stores/nav";
import { useScanStore } from "@/stores/scan";

/** Every package customized at this scope. A row opens that package's own
 *  page, which is where its edits are made; a row for something no longer
 *  installed can only be dropped, since there is no page to open. */
export function CustomizedIndex({
  items,
  scope,
  onRemove,
}: {
  items: CustomizedItem[];
  scope: Scope;
  onRemove: (kind: ItemKind, name: string) => void;
}) {
  const goToPackage = useNavStore((s) => s.goToPackage);
  const installed = useScanStore((s) => s.result?.items ?? []);

  if (items.length === 0) {
    return (
      <p className="pt-1 text-sm text-muted-foreground">{NOTHING_CUSTOMIZED}</p>
    );
  }

  return (
    <div className="flex flex-col divide-y">
      {items.map(({ kind, name, customization }) => {
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
                {kindLabel(kind)} · {customizationSummary(customization)}
              </p>
            </div>
            {here ? (
              <Button
                variant="ghost"
                size="sm"
                onClick={() =>
                  goToPackage(...customizeNav({ kind, name, scope }))
                }
              >
                Open
                <ChevronRight className="size-4" />
              </Button>
            ) : (
              <>
                <span className="text-[13px] text-muted-foreground">
                  {NOT_INSTALLED_HERE}
                </span>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => onRemove(kind, name)}
                >
                  {REMOVE_CUSTOMIZATION}
                </Button>
              </>
            )}
          </div>
        );
      })}
    </div>
  );
}
