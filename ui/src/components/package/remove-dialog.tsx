import type { ItemKind, Scope } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { useAuditStore } from "@/stores/audit";
import { useScanStore } from "@/stores/scan";
import { inEveryPlace } from "@/stores/unsaved-first";

/** Removing a package takes every copy of it with it — it is one thing to
 *  a reader, so it is one action here. The page leaves only once the scan
 *  agrees the package is gone; a failed removal shows its error instead. */
export function RemoveDialog({
  open,
  onOpenChange,
  kind,
  name,
  scopes,
  onGone,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  kind: ItemKind;
  name: string;
  scopes: Scope[];
  onGone: () => void;
}) {
  const { busy, removeItem } = useAuditStore();
  return (
    <ConfirmDialog
      open={open}
      onOpenChange={onOpenChange}
      title={`Remove ${name}?`}
      description="The files kendex manages will be moved to the trash, and it will stop being kept up to date."
      confirmLabel="Remove"
      destructive
      busy={busy}
      onConfirm={() => {
        void (async () => {
          // Every place, or none: the same rule the page's other
          // package-wide actions follow.
          await inEveryPlace(scopes, (scope) => removeItem(scope, kind, name));
          onOpenChange(false);
          const stillHere = useScanStore
            .getState()
            .result?.items.some(
              (item) => item.kind === kind && item.name === name,
            );
          if (!stillHere) onGone();
        })();
      }}
    />
  );
}
