import { useState } from "react";
import type { ItemKind, Scope, UpdateRow } from "@/bindings";
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
  KEEP_AS_FORK_LABEL,
  MULTI_TOOL_FORK_NOTE,
  unforkableCopyNote,
  VIEW_CHANGES_LABEL,
} from "@/lib/copy";
import { harnessName } from "@/lib/labels";
import { sameScope } from "@/lib/scope";
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
  onViewChanges: () => void;
  onResolved: () => void;
}) {
  const busy = useUpdatesStore((s) => s.busy);
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
          {row.forkableHarness ? FORK_NOTICE_DETAIL : whyNoFork}
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
        <Button size="sm" variant="outline" onClick={onViewChanges}>
          {VIEW_CHANGES_LABEL}
        </Button>
        {row.canDiscard ? (
          <Button
            size="sm"
            variant="outline"
            disabled={busy}
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
  onViewChanges: () => void;
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
