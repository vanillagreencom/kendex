import { useState } from "react";
import type { HarnessId, ItemKind, Scope, UpdateRow } from "@/bindings";
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
  derivedForkNote,
  editedInToolsLabel,
  FORK_NOTICE_DETAIL,
  FORK_NOTICE_TITLE,
  KEEP_AS_FORK_LABEL,
  MULTI_TOOL_FORK_NOTE,
  unforkableCopyNote,
  VIEW_CHANGES_LABEL,
  viewChangesInLabel,
} from "@/lib/copy";
import {
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_ONE_AT_A_TIME_NOTE,
} from "@/lib/copy-updates";
import { harnessName } from "@/lib/labels";
import { sameScope } from "@/lib/scope";
import { rowUnsettled } from "@/lib/updates-read-state";
import { useUpdatesStore } from "@/stores/updates";
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
  const checking = useUpdatesStore((s) => s.checking);
  // Discarding applies the retained row's latest commit when the place is
  // held — from rows a failed check left behind, or rows a running check
  // is about to replace, that pins an old version — so the discard waits
  // for a check.
  const held = useUpdatesStore((s) => rowUnsettled(s, row));
  // The fork copies what is on disk and reads nothing off the row, so a
  // failed check does not bar it. It commits, so the work already running
  // does: the same pair the store refuses it on.
  const running = busy || checking;
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const several = row.editedHarnesses.length > 1;
  const whyNoFork = row.derived
    ? // Named where the row knows which packages require this one; a
      // bundle member has no requiring package to name.
      row.requiredBy.length > 0
      ? derivedForkNote(row.requiredBy)
      : DERIVED_FORK_NOTE
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
          {row.forkableHarness ? FORK_NOTICE_DETAIL : whyNoFork}
        </p>
      </div>
      <div className="flex shrink-0 flex-wrap gap-2">
        {row.forkableHarness ? (
          <Button
            size="sm"
            disabled={running}
            title={running ? UPDATES_ONE_AT_A_TIME_NOTE : undefined}
            onClick={() => void keepAsOwn(row).then(onResolved)}
          >
            {KEEP_AS_FORK_LABEL}
          </Button>
        ) : null}
        {several ? (
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
            disabled={busy || held}
            title={held ? UPDATE_NEEDS_CHECK_NOTE : undefined}
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
        description={DISCARD_EDITS_CONFIRM_BODY}
        confirmLabel={DISCARD_EDITS_CONFIRM_LABEL}
        destructive
        busy={busy}
        confirmDisabled={held}
        confirmDisabledNote={UPDATE_NEEDS_CHECK_NOTE}
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

/** The page-level wrapper: shows the notice exactly when this package has
 *  edits on disk and is not already a fork. */
export function EditedNotice({
  scope,
  kind,
  name,
  alreadyForked,
  onViewChanges,
  onResolved,
}: {
  scope: Scope;
  kind: ItemKind;
  name: string;
  alreadyForked: boolean;
  onViewChanges: (harness?: HarnessId) => void;
  onResolved: () => void;
}) {
  const row = useUpdatesStore((s) =>
    s.rows.find(
      (row) =>
        row.kind === kind &&
        row.name === name &&
        sameScope(row.scope, scope) &&
        row.blockedByLocalEdit,
    ),
  );
  if (!row || alreadyForked) return null;
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
