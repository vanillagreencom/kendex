import type { ItemKind, Scope } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { useAuditStore } from "@/stores/audit";
import { useScanStore } from "@/stores/scan";

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
          // One failure stops the rest: a removal that could not finish
          // leaves the item where it was, and carrying on would take it
          // out of the other scopes anyway.
          for (const scope of scopes) {
            if (!(await removeItem(scope, kind, name))) return;
          }
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
