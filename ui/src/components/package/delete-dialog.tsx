import { useEffect } from "react";
import type { ItemKind, Scope } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import {
  DELETE_BODY,
  DELETE_LABEL,
  DELETE_PLACES_LABEL,
  deleteTitle,
  REINSTALL_OWN,
  reinstallFrom,
} from "@/lib/copy-projects";
import { scopePath } from "@/lib/labels";
import { scopeKey } from "@/lib/scope";
import { placeName } from "@/lib/update-groups";
import { useAuditStore } from "@/stores/audit";
import { originFor, useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";

/** Where a deleted package can be had again, or null while nobody can
 *  say — a join that has not landed says nothing rather than "your own". */
function useReinstallNote(
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): string | null {
  const rows = useProvenanceStore((s) => s.rows);
  const loaded = useProvenanceStore((s) => s.loaded);
  const load = useProvenanceStore((s) => s.load);
  // This dialog can be the first thing to want the join: a package page
  // opened straight from a link renders its own Details block beside it,
  // but nothing guarantees that block asked first.
  useEffect(() => {
    if (!loaded) void load();
  }, [loaded, load]);
  if (!loaded) return null;
  const origin = originFor(rows, kind, name, scopes);
  if (origin?.origin === "marketplace") return reinstallFrom(origin.source);
  return origin?.origin === "own" ? REINSTALL_OWN : null;
}

/** Deleting a package takes every copy of it with it — it is one thing to
 *  a reader, so it is one action here, and the dialog names every place it
 *  reaches before it runs. Per-place removal is on the Projects tab.
 *
 *  The page leaves only once the scan agrees the package is gone; a failed
 *  deletion shows its error instead. */
export function DeleteDialog({
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
  const reinstall = useReinstallNote(kind, name, scopes);
  return (
    <ConfirmDialog
      open={open}
      onOpenChange={onOpenChange}
      title={deleteTitle(name)}
      description={DELETE_BODY}
      confirmLabel={DELETE_LABEL}
      destructive
      busy={busy}
      onConfirm={() => {
        void (async () => {
          // One failure stops the rest: a deletion that could not finish
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
    >
      <div className="flex flex-col gap-2">
        <p className="text-sm font-medium">{DELETE_PLACES_LABEL}</p>
        <ul className="flex flex-col gap-1">
          {scopes.map((scope) => (
            <li key={scopeKey(scope)} className="flex gap-2 text-sm">
              <span className="shrink-0">{placeName(scope, scopes)}</span>
              {scopePath(scope) ? (
                <span className="min-w-0 truncate text-muted-foreground">
                  {scopePath(scope)}
                </span>
              ) : null}
            </li>
          ))}
        </ul>
        {reinstall ? (
          <p className="text-sm text-muted-foreground">{reinstall}</p>
        ) : null}
      </div>
    </ConfirmDialog>
  );
}
