import { useState } from "react";
import type { UpdateRow } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { Button } from "@/components/ui/button";
import {
  CUSTOMIZED_HERE_LABEL,
  DISCARD_EDITS_CONFIRM_BODY,
  DISCARD_EDITS_CONFIRM_LABEL,
  DISCARD_EDITS_CONFIRM_TITLE,
  KEEP_AS_FORK_LABEL,
  UNFORKABLE_EDIT_NOTE,
  USE_NEW_VERSION_LABEL,
} from "@/lib/copy";
import { scopeKey } from "@/lib/scope";
import { keepAsOwn, takeNewVersion } from "@/stores/updates-edits";

/** A place whose files were edited by hand: the update waits on a
 *  decision, made here per place because an edit in one project says
 *  nothing about the copy in another. Both choices run through the store,
 *  so every control on the page sees one busy flag while they work. */
export function CustomizedActions({
  row,
  busy,
}: {
  row: UpdateRow;
  busy: boolean;
}) {
  const [confirmDiscard, setConfirmDiscard] = useState(false);

  return (
    <>
      <span className="mr-1 text-xs text-warning">{CUSTOMIZED_HERE_LABEL}</span>
      {row.forkableHarness ? (
        <Button
          size="sm"
          variant="outline"
          disabled={busy}
          onClick={() => void keepAsOwn(row)}
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
        disabled={busy}
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
        onConfirm={() =>
          void takeNewVersion(row).then(() => setConfirmDiscard(false))
        }
      />
    </>
  );
}
