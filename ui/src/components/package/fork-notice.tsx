import { useState } from "react";
import type { HarnessId, UpdateRow } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { StatusDot } from "@/components/status-dot";
import { Button } from "@/components/ui/button";
import {
  DERIVED_FORK_NOTE,
  DISCARD_ALL_EDITS_LABEL,
  DISCARD_EDITS_CONFIRM_BODY,
  DISCARD_EDITS_CONFIRM_LABEL,
  DISCARD_EDITS_CONFIRM_TITLE,
  DISCARD_EDITS_LABEL,
  editedInToolsLabel,
  FORK_NOTICE_DETAIL,
  FORK_NOTICE_TITLE,
  FORKED_DISCARD_CONFIRM_BODY,
  FORKED_NOTICE_DETAIL,
  FORKED_UNREADABLE_DETAIL,
  KEEP_AS_FORK_LABEL,
  MULTI_TOOL_FORK_NOTE,
  unforkableCopyNote,
  VIEW_CHANGES_LABEL,
  viewChangesInLabel,
} from "@/lib/copy-forks";
import { harnessName } from "@/lib/labels";
import { canApplyUpdates, useUpdatesStore } from "@/stores/updates";
import { keepAsOwn, takeNewVersion } from "@/stores/updates-edits";

/** The package page's edited-files notice: the app found changes it did
 *  not write, held everything, and here are the ways forward — the same
 *  facts the Updates page acts on, so neither screen offers a fork the
 *  engine would refuse or one that would drop another tool's edit. */
export function ForkNotice({
  row,
  onViewChanges,
  onResolved,
}: {
  row: UpdateRow;
  /** Opens the comparison for one tool's edited copy — the primary
   *  rendering when no tool is named. */
  onViewChanges: (harness?: HarnessId) => void;
  onResolved: () => void;
}) {
  const busy = useUpdatesStore((s) => s.busy);
  // The same button does two different things: a place that can move takes
  // the revision this read reported, so a check still in flight would let
  // it apply a version that is no longer the newest. A place that can only
  // drop its edits applies none, and stays reachable — a check that failed
  // must not strand an edited place. Same rule as the Updates page.
  const canApply = useUpdatesStore(canApplyUpdates);
  const holdLatest = row.canTakeLatest && !canApply;
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const several = row.editedHarnesses.length > 1;
  const whyNoFork = row.derived
    ? DERIVED_FORK_NOTE
    : several
      ? MULTI_TOOL_FORK_NOTE
      : row.editedHarnesses[0]
        ? unforkableCopyNote(harnessName(row.editedHarnesses[0]))
        : null;

  return (
    <div className="flex items-start gap-3 rounded-xl border bg-card p-4">
      <StatusDot tone="warning" className="mt-1" />
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium">{FORK_NOTICE_TITLE}</p>
        <p className="text-sm text-muted-foreground">
          {several
            ? `${editedInToolsLabel(row.editedHarnesses.map(harnessName))} `
            : null}
          {row.forked
            ? row.canDiscard
              ? FORKED_NOTICE_DETAIL
              : FORKED_UNREADABLE_DETAIL
            : row.forkableHarness
              ? FORK_NOTICE_DETAIL
              : whyNoFork}
        </p>
      </div>
      <div className="flex shrink-0 flex-wrap gap-2">
        {row.forkableHarness ? (
          <Button
            size="sm"
            disabled={busy}
            onClick={() => void keepAsOwn(row).then(onResolved)}
          >
            {KEEP_AS_FORK_LABEL}
          </Button>
        ) : null}
        {/* A comparison needs two sides, and a fork's declaration resolves
            to its own local source: there is no catalog version left to put
            beside the edit, so the button would open nothing. */}
        {row.forked ? null : several ? (
          row.editedHarnesses.map((harness) => (
            <Button
              key={harness}
              size="sm"
              variant="outline"
              onClick={() => onViewChanges(harness)}
            >
              {viewChangesInLabel(harnessName(harness))}
            </Button>
          ))
        ) : (
          <Button
            size="sm"
            variant="outline"
            onClick={() => onViewChanges(row.editedHarnesses[0])}
          >
            {VIEW_CHANGES_LABEL}
          </Button>
        )}
        {row.canDiscard ? (
          <Button
            size="sm"
            variant="outline"
            disabled={busy || holdLatest}
            onClick={() => setConfirmDiscard(true)}
          >
            {several ? DISCARD_ALL_EDITS_LABEL : DISCARD_EDITS_LABEL}
          </Button>
        ) : null}
      </div>
      <ConfirmDialog
        open={confirmDiscard}
        onOpenChange={setConfirmDiscard}
        title={DISCARD_EDITS_CONFIRM_TITLE}
        description={
          row.forked ? FORKED_DISCARD_CONFIRM_BODY : DISCARD_EDITS_CONFIRM_BODY
        }
        confirmLabel={DISCARD_EDITS_CONFIRM_LABEL}
        destructive
        busy={busy}
        holdConfirm={holdLatest}
        onConfirm={() =>
          void takeNewVersion(row).then(() => {
            setConfirmDiscard(false);
            onResolved();
          })
        }
      />
    </div>
  );
}

/** The page-level wrapper: shows the notice exactly when this place's files
 *  were edited by hand. A fork gets it too — the keep-as-your-own half is
 *  spent, but its own copy is still there to put back, and a held state
 *  with no way out is not a state to leave someone in. The row arrives from
 *  the page's own per-place join, so the notice, the header badge and the
 *  Update button can never disagree about one place. */
export function EditedNotice({
  row,
  onViewChanges,
  onResolved,
}: {
  /** This place's update row when its files were edited by hand, else null. */
  row: UpdateRow | null;
  onViewChanges: (harness?: HarnessId) => void;
  onResolved: () => void;
}) {
  if (!row) return null;
  return (
    <div className="mb-6">
      <ForkNotice
        row={row}
        onViewChanges={onViewChanges}
        onResolved={onResolved}
      />
    </div>
  );
}
