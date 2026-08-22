import { useState } from "react";
import type { UpdateRow } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { Button } from "@/components/ui/button";
import {
  DISCARD_EDITS_CONFIRM_BODY,
  DISCARD_EDITS_CONFIRM_LABEL,
  DISCARD_EDITS_CONFIRM_TITLE,
  DISCARD_EDITS_LABEL,
  KEEP_AS_FORK_LABEL,
} from "@/lib/copy-forks";
import {
  CUSTOMIZED_HERE_LABEL,
  DERIVED_EDIT_NOTE,
  MULTI_TOOL_EDIT_NOTE,
  UNFORKABLE_EDIT_NOTE,
  USE_NEW_VERSION_LABEL,
} from "@/lib/copy-updates";
import { scopeKey } from "@/lib/scope";
import { canApplyUpdates, useUpdatesStore } from "@/stores/updates";
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
  // Taking the new version applies the revision this read reported; the
  // same button dropping edits alone applies none, and stays available —
  // a failed check must not strand an edited place.
  const canApply = useUpdatesStore(canApplyUpdates);
  // Taking the newest applies the revision the last read named, so a read
  // still on its way holds it — at the button and at the confirmation
  // alike, since a dialog already open when that read fails would otherwise
  // still apply what it is about to replace.
  const holdLatest = row.canTakeLatest && !canApply;
  const whyNoFork = row.derived
    ? DERIVED_EDIT_NOTE
    : row.editedHarnesses.length > 1
      ? MULTI_TOOL_EDIT_NOTE
      : UNFORKABLE_EDIT_NOTE;

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
        <span className="mr-1 text-xs text-muted-foreground" title={whyNoFork}>
          {whyNoFork}
        </span>
      )}
      {/* A source that no longer carries the package has nothing to put
          in the edits' place; the row's badge already says so. A place
          that can drop its edits but not move — held by its bundle or
          parent — is offered exactly that, never a newer version. */}
      {row.canDiscard ? (
        <Button
          size="sm"
          variant="outline"
          disabled={busy || holdLatest}
          onClick={() => setConfirmDiscard(true)}
        >
          {row.canTakeLatest ? USE_NEW_VERSION_LABEL : DISCARD_EDITS_LABEL}
        </Button>
      ) : null}
      <ConfirmDialog
        key={scopeKey(row.scope)}
        open={confirmDiscard}
        onOpenChange={setConfirmDiscard}
        title={DISCARD_EDITS_CONFIRM_TITLE}
        description={DISCARD_EDITS_CONFIRM_BODY}
        confirmLabel={DISCARD_EDITS_CONFIRM_LABEL}
        destructive
        busy={busy}
        holdConfirm={holdLatest}
        onConfirm={() =>
          void takeNewVersion(row).then(() => setConfirmDiscard(false))
        }
      />
    </>
  );
}
