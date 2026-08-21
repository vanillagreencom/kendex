import {
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  RefreshCw,
} from "lucide-react";
import { useEffect, useState } from "react";
import type { UpdateRow } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { EmptyState } from "@/components/empty-state";
import { PageHeader } from "@/components/page-header";
import { Button } from "@/components/ui/button";
import { UpdatesTable } from "@/components/updates-table";
import {
  CHECK_FOR_UPDATES_LABEL,
  hiddenUpdatesLabel,
  IGNORE_CONFIRM_BODY,
  IGNORE_CONFIRM_LABEL,
  ignoreConfirmTitle,
  UPDATE_ALL_LABEL,
  UPDATES_EMPTY,
  UPDATES_EMPTY_BODY,
  UPDATES_UNCHECKED_TITLE,
} from "@/lib/copy";
import { FOLLOW_SOURCE_HELP, updatesSubtitle } from "@/lib/copy-updates";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { packageCount, updatablePlaces } from "@/lib/update-groups";
import { cn } from "@/lib/utils";
import {
  hiddenUpdates,
  useUpdatesStore,
  visibleUpdates,
} from "@/stores/updates";

/** Which packages have newer versions, what changed, and per-package
 *  control over how loudly to hear about it. */
export function UpdatesPage() {
  const { rows, warnings, busy, checking, check, updateRows } =
    useUpdatesStore();
  const load = useUpdatesStore((s) => s.load);
  const [showHidden, setShowHidden] = useState(false);
  const [confirmIgnore, setConfirmIgnore] = useState<UpdateRow | null>(null);

  useEffect(() => {
    void load();
  }, [load]);

  const visible = visibleUpdates(rows);
  const hidden = hiddenUpdates(rows);
  const HiddenChevron = showHidden ? ChevronDown : ChevronRight;

  // With nothing to update there is nothing to introduce: a title and a
  // sentence explaining a list that isn't there is furniture around good
  // news. The sidebar already says which page this is.
  if (visible.length === 0 && hidden.length === 0 && warnings.length === 0) {
    return (
      <div className="flex min-h-full items-center justify-center">
        <EmptyState
          icon={CheckCircle2}
          title={UPDATES_EMPTY}
          action={
            <Button
              variant="outline"
              disabled={checking}
              onClick={() => void check()}
            >
              {CHECK_FOR_UPDATES_LABEL}
            </Button>
          }
        >
          {UPDATES_EMPTY_BODY}
        </EmptyState>
      </div>
    );
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <PageHeader
        title="Updates"
        wide
        subtitle={
          visible.length > 0 ? (
            <>
              {updatesSubtitle(packageCount(visible), visible.length)}
              <span className="block text-muted-foreground">
                {FOLLOW_SOURCE_HELP}
              </span>
            </>
          ) : (
            FOLLOW_SOURCE_HELP
          )
        }
        action={
          <div className="flex gap-2">
            {visible.length > 0 ? (
              <Button
                size="sm"
                variant="outline"
                disabled={checking}
                onClick={() => void check()}
              >
                <RefreshCw
                  className={cn("size-3.5", checking && "animate-spin")}
                />
                {CHECK_FOR_UPDATES_LABEL}
              </Button>
            ) : null}
            {packageCount(visible) > 1 ? (
              <Button
                size="sm"
                disabled={busy || updatablePlaces(visible).length === 0}
                onClick={() => void updateRows(visible)}
              >
                {UPDATE_ALL_LABEL}
              </Button>
            ) : null}
          </div>
        }
      />
      <div className={cn("min-h-0 flex-1 overflow-y-auto", PAGE_GUTTER)}>
        <div className={cn("pb-8", WIDE_CONTENT_WIDTH)}>
          {visible.length === 0 ? (
            <EmptyState icon={CheckCircle2} title={UPDATES_EMPTY}>
              {UPDATES_EMPTY_BODY}
            </EmptyState>
          ) : (
            <UpdatesTable rows={visible} onIgnore={setConfirmIgnore} />
          )}
          {warnings.length > 0 ? (
            <div className="mt-8">
              <p className="text-sm font-medium">{UPDATES_UNCHECKED_TITLE}</p>
              <div className="mt-1 space-y-1">
                {warnings.map((warning) => (
                  <p
                    key={`${warning.kind}:${warning.name}:${warning.message}`}
                    className="text-xs text-muted-foreground"
                  >
                    {warning.name}: {warning.message}
                    {warning.remediation ? ` — ${warning.remediation}` : ""}
                  </p>
                ))}
              </div>
            </div>
          ) : null}
          {hidden.length > 0 ? (
            <div className="mt-8">
              <button
                type="button"
                className="flex items-center gap-1.5 text-sm text-muted-foreground hover:text-foreground"
                onClick={() => setShowHidden((value) => !value)}
              >
                <HiddenChevron className="size-3.5" />
                {hiddenUpdatesLabel(packageCount(hidden))}
              </button>
              {showHidden ? (
                <div className="mt-2 opacity-80">
                  <UpdatesTable rows={hidden} />
                </div>
              ) : null}
            </div>
          ) : null}
        </div>
      </div>
      <ConfirmDialog
        open={confirmIgnore != null}
        onOpenChange={(open) => {
          if (!open) setConfirmIgnore(null);
        }}
        title={confirmIgnore ? ignoreConfirmTitle(confirmIgnore.name) : ""}
        description={IGNORE_CONFIRM_BODY}
        confirmLabel={IGNORE_CONFIRM_LABEL}
        busy={busy}
        onConfirm={() => {
          if (!confirmIgnore) return;
          void useUpdatesStore
            .getState()
            .setIgnored(confirmIgnore, true)
            .then(() => setConfirmIgnore(null));
        }}
      />
    </div>
  );
}
