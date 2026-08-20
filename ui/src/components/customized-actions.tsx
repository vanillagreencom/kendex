import { useState } from "react";
import { toast } from "sonner";
import { commands, type UpdateRow } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { Button } from "@/components/ui/button";
import {
  CUSTOMIZED_HERE_LABEL,
  DISCARD_EDITS_CONFIRM_BODY,
  DISCARD_EDITS_CONFIRM_LABEL,
  DISCARD_EDITS_CONFIRM_TITLE,
  FORK_ERROR_TITLE,
  forkedToastLabel,
  KEEP_AS_FORK_LABEL,
  UNFORKABLE_EDIT_NOTE,
  USE_NEW_VERSION_LABEL,
} from "@/lib/copy";
import { packageDisplayName } from "@/lib/labels";
import { scopeKey } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";
import { useProblemsStore } from "@/stores/problems";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";

/** A place whose files were edited by hand: the update waits on a
 *  decision, made here per place because an edit in one project says
 *  nothing about the copy in another. */
export function CustomizedActions({
  row,
  storeBusy,
}: {
  row: UpdateRow;
  /** Another update in flight must finish before a fork rewrites the
   *  manifest; the store's busy covers every apply, the local one only
   *  this row's. */
  storeBusy: boolean;
}) {
  const showError = useProblemsStore((s) => s.showError);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const [busy, setBusy] = useState(false);
  // Forking captures one rendering's bytes, and only some tools' copies
  // read back as source — the row names the edited one a fork can take.
  const harness = row.forkableHarness;

  const refreshAll = async () => {
    await useScanStore.getState().refresh();
    await useAuditStore.getState().refresh({ force: true });
    await useUpdatesStore.getState().load();
  };

  const keepAsOwn = async () => {
    if (!harness) return;
    setBusy(true);
    const response = await commands.packageFork(
      row.scope,
      row.kind,
      row.name,
      harness,
    );
    setBusy(false);
    if (response.status === "error") {
      showError({ title: FORK_ERROR_TITLE, message: response.error });
      return;
    }
    toast.success(forkedToastLabel(packageDisplayName(row)));
    await refreshAll();
  };

  const discardEdits = async () => {
    setBusy(true);
    const response = await commands.applyDiscardEdits(
      row.scope,
      row.kind,
      row.name,
    );
    setBusy(false);
    setConfirmDiscard(false);
    if (response.status === "error") {
      showError({ title: FORK_ERROR_TITLE, message: response.error });
      return;
    }
    await refreshAll();
  };

  return (
    <>
      <span className="mr-1 text-xs text-warning">{CUSTOMIZED_HERE_LABEL}</span>
      {harness ? (
        <Button
          size="sm"
          variant="outline"
          disabled={busy || storeBusy}
          onClick={() => void keepAsOwn()}
        >
          {KEEP_AS_FORK_LABEL}
        </Button>
      ) : (
        <span
          className="mr-1 text-xs text-muted-foreground"
          title={UNFORKABLE_EDIT_NOTE}
        >
          {UNFORKABLE_EDIT_NOTE}
        </span>
      )}
      <Button
        size="sm"
        variant="outline"
        disabled={busy || storeBusy}
        onClick={() => setConfirmDiscard(true)}
      >
        {USE_NEW_VERSION_LABEL}
      </Button>
      <ConfirmDialog
        key={scopeKey(row.scope)}
        open={confirmDiscard}
        onOpenChange={setConfirmDiscard}
        title={DISCARD_EDITS_CONFIRM_TITLE}
        description={DISCARD_EDITS_CONFIRM_BODY}
        confirmLabel={DISCARD_EDITS_CONFIRM_LABEL}
        destructive
        busy={busy}
        onConfirm={() => void discardEdits()}
      />
    </>
  );
}
