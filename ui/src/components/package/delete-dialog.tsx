import { useEffect, useState } from "react";
import type { ItemKind, Scope } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import {
  DELETE_BODY,
  DELETE_LABEL,
  DELETE_PLACES_LABEL,
  deleteTitle,
  REINSTALL_OWN,
  REINSTALL_READING,
  REINSTALL_UNREAD,
  reinstallFrom,
} from "@/lib/copy-projects";
import { scopePath } from "@/lib/labels";
import { scopeKey } from "@/lib/scope";
import { placeName } from "@/lib/update-groups";
import { useAuditStore } from "@/stores/audit";
import { originsFor, useProvenanceStore } from "@/stores/provenance";
import { useScanStore } from "@/stores/scan";

/** How the read behind the note stands. Three answers the dialog must
 *  keep apart: one still running, one that failed, and one that landed.
 *  Only the last may be confirmed over. */
type NoteRead = "reading" | "landed" | "failed";

/** Every marketplace a deleted package can be had from again, beside how
 *  the read that found them went.
 *
 *  The read is taken on every open rather than once. `loaded` says only
 *  that some snapshot landed, never that it covers this installation:
 *  installing refreshes the scan and the audit and leaves this join
 *  alone, so a Library visit before an install would answer for a package
 *  that did not exist yet. */
function useReinstallNote(
  kind: ItemKind,
  name: string,
  scopes: Scope[],
  open: boolean,
): { note: string | null; read: NoteRead } {
  const rows = useProvenanceStore((s) => s.rows);
  const reload = useProvenanceStore((s) => s.reload);
  const [read, setRead] = useState<NoteRead>("reading");
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    setRead("reading");
    void reload().then((landed) => {
      if (!cancelled) setRead(landed ? "landed" : "failed");
    });
    return () => {
      cancelled = true;
    };
  }, [open, reload]);
  if (read !== "landed") return { note: null, read };
  const origins = originsFor(rows, kind, name, scopes);
  // Every marketplace among them, sorted so the note reads the same on
  // every open: this deletion reaches each place, and each place records
  // the source it was installed from, which need not be its neighbour's.
  const marketplaces = [
    ...new Set(
      origins.flatMap((one) =>
        one.origin === "marketplace" ? [one.source] : [],
      ),
    ),
  ].sort();
  if (marketplaces.length > 0)
    return { note: reinstallFrom(marketplaces), read };
  // No marketplace to name. "Your own" is a claim, so it is made only
  // where a row actually says so, never from an origin nothing recorded.
  return {
    note: origins.some((one) => one.origin === "own") ? REINSTALL_OWN : null,
    read,
  };
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
  const { note, read } = useReinstallNote(kind, name, scopes, open);
  return (
    <ConfirmDialog
      open={open}
      onOpenChange={onOpenChange}
      title={deleteTitle(name)}
      description={DELETE_BODY}
      confirmLabel={DELETE_LABEL}
      destructive
      busy={busy}
      // The dialog exists to say where the package can be had again, so it
      // does not confirm a deletion while that is unknown. Cancel stays
      // live either way.
      confirmDisabled={read !== "landed"}
      confirmDisabledNote={
        read === "failed" ? REINSTALL_UNREAD : REINSTALL_READING
      }
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
        {read === "reading" ? (
          <p className="text-sm text-muted-foreground">{REINSTALL_READING}</p>
        ) : read === "failed" ? (
          <p className="text-sm text-muted-foreground">{REINSTALL_UNREAD}</p>
        ) : note ? (
          <p className="text-sm text-muted-foreground">{note}</p>
        ) : null}
      </div>
    </ConfirmDialog>
  );
}
