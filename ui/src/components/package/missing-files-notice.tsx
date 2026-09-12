import type { ItemKind, Scope } from "@/bindings";
import { StatusDot } from "@/components/status-dot";
import { Button } from "@/components/ui/button";
import {
  MISSING_FILES_NOTICE_DETAIL,
  MISSING_FILES_NOTICE_TITLE,
  repairedToastLabel,
} from "@/lib/copy";
import { REPAIR_LABEL } from "@/lib/copy-setup";
import {
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_ONE_AT_A_TIME_NOTE,
} from "@/lib/copy-updates";
import { sameScope } from "@/lib/scope";
import { readUnsettled } from "@/lib/updates-read-state";
import { useUpdatesStore } from "@/stores/updates";

/** The package page's missing-files notice: a file kendex installed at
 *  this place is gone, and the plan that would put it back is the same
 *  one an update runs — so the repair is that apply, said as a repair.
 *  Shown exactly when this place's row carries the fact. */
export function MissingFilesNotice({
  scope,
  kind,
  name,
  onResolved,
}: {
  scope: Scope;
  kind: ItemKind;
  name: string;
  onResolved: () => void;
}) {
  const row = useUpdatesStore((s) =>
    s.rows.find(
      (row) =>
        row.kind === kind &&
        row.name === name &&
        sameScope(row.scope, scope) &&
        row.filesMissing,
    ),
  );
  const busy = useUpdatesStore((s) => s.busy);
  // The apply reads the row it is handed, so a row a failed check left
  // behind, or one a running check is about to replace, waits for the
  // check — the same hold `updateOne` refuses on.
  const held = useUpdatesStore(readUnsettled);
  const updateOne = useUpdatesStore((s) => s.updateOne);
  if (!row) return null;
  return (
    <div className="mb-6 flex items-start gap-3 rounded-xl border bg-card p-4">
      <StatusDot tone="warning" className="mt-1" />
      <div className="min-w-0 flex-1">
        <p className="text-sm font-medium">{MISSING_FILES_NOTICE_TITLE}</p>
        <p className="text-sm text-muted-foreground">
          {MISSING_FILES_NOTICE_DETAIL}
        </p>
      </div>
      <Button
        size="sm"
        disabled={busy || held}
        title={
          held
            ? UPDATE_NEEDS_CHECK_NOTE
            : busy
              ? UPDATES_ONE_AT_A_TIME_NOTE
              : undefined
        }
        onClick={() =>
          void updateOne(row, repairedToastLabel(row.name)).then(onResolved)
        }
      >
        {REPAIR_LABEL}
      </Button>
    </div>
  );
}
