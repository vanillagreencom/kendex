import { useEffect, useState } from "react";
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
import {
  joinCurrent,
  originsFor,
  useProvenanceStore,
} from "@/stores/provenance";

/** Every marketplace a deleted package can be had from again.
 *
 *  The read is taken on every open rather than once: `loaded` says a
 *  snapshot landed, never that it covers this installation, and the rows
 *  standing from an earlier open may answer for a different one. A
 *  marketplace named wrongly at the confirm step of a deletion is worse
 *  than none.
 *
 *  So there is no note until this open has asked AND the store says the
 *  rows are current — a read that failed names nothing, and neither does
 *  one still coming. That second half is store state, not this call's
 *  answer, so the note arrives with whichever read lands. Delete is not
 *  held for it either way: the note is where to get the package again, not
 *  what the deletion does, and the engine answers for the removal. */
function useReinstallNote(
  kind: ItemKind,
  name: string,
  scopes: Scope[],
  open: boolean,
): string | null {
  const rows = useProvenanceStore((s) => s.rows);
  const current = useProvenanceStore(joinCurrent);
  const reload = useProvenanceStore((s) => s.reload);
  const [asked, setAsked] = useState(false);
  // Cleared on the way out as well as the way in: the dialog is mounted
  // whether or not it is open, so a flag left standing from the last open
  // is a note built from that open's rows on the next one's first render.
  useEffect(() => {
    setAsked(false);
    if (!open) return;
    let cancelled = false;
    void reload().then(() => {
      if (!cancelled) setAsked(true);
    });
    return () => {
      cancelled = true;
    };
  }, [open, reload]);
  if (!asked || !current) return null;
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
  if (marketplaces.length > 0) return reinstallFrom(marketplaces);
  // No marketplace to name. "Your own" is a claim, so it is made only
  // where a row actually says so, never from an origin nothing recorded.
  return origins.some((one) => one.origin === "own") ? REINSTALL_OWN : null;
}

/** Deleting a package takes every copy of it with it — it is one thing to
 *  a reader, so it is one action here, and the dialog names every place it
 *  reaches before it runs. Per-place removal is on the Projects tab.
 *
 *  Whether the page then leaves is the page's own judgment, not this
 *  dialog's: `package.tsx` navigates once the scan behind the removals
 *  lands and no longer knows the package. This dialog closes and says what
 *  a failed removal said, and nothing more. */
export function DeleteDialog({
  open,
  onOpenChange,
  kind,
  name,
  scopes,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  kind: ItemKind;
  name: string;
  scopes: Scope[];
}) {
  const { busy, removeItem } = useAuditStore();
  const note = useReinstallNote(kind, name, scopes, open);
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
        {note ? <p className="text-sm text-muted-foreground">{note}</p> : null}
      </div>
    </ConfirmDialog>
  );
}
