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
} from "@/lib/copy";
import {
  CUSTOMIZED_HERE_LABEL,
  DERIVED_EDIT_NOTE,
  MULTI_TOOL_EDIT_NOTE,
  UNFORKABLE_EDIT_NOTE,
  USE_NEW_VERSION_LABEL,
} from "@/lib/copy-updates";
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
          disabled={busy}
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
        onConfirm={() =>
          void takeNewVersion(row).then(() => setConfirmDiscard(false))
        }
      />
    </>
  );
}
