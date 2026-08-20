import { useState } from "react";
import { toast } from "sonner";
import {
  commands,
  type HarnessId,
  type ItemKind,
  type Scope,
} from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { StatusDot } from "@/components/status-dot";
import { Button } from "@/components/ui/button";
import {
  DISCARD_EDITS_CONFIRM_BODY,
  DISCARD_EDITS_CONFIRM_LABEL,
  DISCARD_EDITS_CONFIRM_TITLE,
  DISCARD_EDITS_LABEL,
  FORK_ERROR_TITLE,
  FORK_NOTICE_DETAIL,
  FORK_NOTICE_TITLE,
  forkedToastLabel,
  KEEP_AS_FORK_LABEL,
  VIEW_CHANGES_LABEL,
} from "@/lib/copy";
import { sameScope } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";
import { useProblemsStore } from "@/stores/problems";
import { useScanStore } from "@/stores/scan";
import { useUpdatesStore } from "@/stores/updates";

/** The package page's edited-files notice: the app found changes it did
 *  not write, held everything, and here are the three ways forward. */
export function ForkNotice({
  scope,
  kind,
  name,
  harness,
  onViewChanges,
  onResolved,
}: {
  scope: Scope;
  kind: ItemKind;
  name: string;
  harness: HarnessId;
  onViewChanges: () => void;
  onResolved: () => void;
}) {
  const showError = useProblemsStore((s) => s.showError);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const [busy, setBusy] = useState(false);

  const refreshAll = async () => {
    await useScanStore.getState().refresh();
    await useAuditStore.getState().refresh({ force: true });
    await useUpdatesStore.getState().load();
    onResolved();
  };

  const keepAsFork = () => {
    setBusy(true);
    void commands
      .packageFork(scope, kind, name, harness)
      .then(async (response) => {
        setBusy(false);
        if (response.status === "error") {
          showError({ title: FORK_ERROR_TITLE, message: response.error });
          return;
        }
        toast.success(forkedToastLabel(name));
        await refreshAll();
      });
  };

  return (
    <div className="flex items-start gap-3 rounded-xl border bg-card p-4">
      <StatusDot tone="warning" className="mt-1" />
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium">{FORK_NOTICE_TITLE}</p>
        <p className="text-sm text-muted-foreground">{FORK_NOTICE_DETAIL}</p>
      </div>
      <div className="flex shrink-0 flex-wrap gap-2">
        <Button size="sm" disabled={busy} onClick={keepAsFork}>
          {KEEP_AS_FORK_LABEL}
        </Button>
        <Button size="sm" variant="outline" onClick={onViewChanges}>
          {VIEW_CHANGES_LABEL}
        </Button>
        <Button
          size="sm"
          variant="outline"
          disabled={busy}
          onClick={() => setConfirmDiscard(true)}
        >
          {DISCARD_EDITS_LABEL}
        </Button>
      </div>
      <ConfirmDialog
        open={confirmDiscard}
        onOpenChange={setConfirmDiscard}
        title={DISCARD_EDITS_CONFIRM_TITLE}
        description={DISCARD_EDITS_CONFIRM_BODY}
        confirmLabel={DISCARD_EDITS_CONFIRM_LABEL}
        destructive
        busy={busy}
        onConfirm={() => {
          setBusy(true);
          void commands
            .applyDiscardEdits(scope, kind, name, null)
            .then(async (response) => {
              setBusy(false);
              setConfirmDiscard(false);
              if (response.status === "error") {
                showError({ title: FORK_ERROR_TITLE, message: response.error });
                return;
              }
              await refreshAll();
            });
        }}
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
  harness,
  alreadyForked,
  onViewChanges,
  onResolved,
}: {
  scope: Scope;
  kind: ItemKind;
  name: string;
  harness: HarnessId;
  alreadyForked: boolean;
  onViewChanges: () => void;
  onResolved: () => void;
}) {
  const rows = useUpdatesStore((s) => s.rows);
  const edited = rows.some(
    (row) =>
      row.kind === kind &&
      row.name === name &&
      sameScope(row.scope, scope) &&
      row.blockedByLocalEdit,
  );
  if (!edited || alreadyForked) return null;
  return (
    <div className="mb-6">
      <ForkNotice
        scope={scope}
        kind={kind}
        name={name}
        harness={harness}
        onViewChanges={onViewChanges}
        onResolved={onResolved}
      />
    </div>
  );
}
