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
import { DotSpinner } from "@/components/loading";
import { PageHeader } from "@/components/page-header";
import { StatusNote } from "@/components/status-note";
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
import {
  FOLLOW_SOURCE_HELP,
  UPDATES_CHECKING,
  UPDATES_UNCONFIRMED_BODY,
  UPDATES_UNCONFIRMED_TITLE,
  updatesSubtitle,
} from "@/lib/copy-updates";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { packageCount, updatablePlaces } from "@/lib/update-groups";
import { hiddenUpdates, visibleUpdates } from "@/lib/update-rows";
import { cn } from "@/lib/utils";
import { canApplyUpdates, useUpdatesStore } from "@/stores/updates";

/** Which packages have newer versions, what changed, and per-package
 *  control over how loudly to hear about it. */
export function UpdatesPage() {
  const { rows, warnings, busy, checking, error, check, updateRows } =
    useUpdatesStore();
  // Nothing has answered yet, so there is nothing to call up to date.
  const loaded = useUpdatesStore((s) => s.loaded);
  const canApply = useUpdatesStore(canApplyUpdates);
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
  // "You're up to date" over a read that failed is the same claim as a
  // place marked untouched when nobody had looked: the note below says what
  // actually happened, and offers the retry.
  if (!loaded && !error) {
    return (
      <div className="flex min-h-full items-center justify-center">
        <p className="flex items-center gap-2 text-sm text-muted-foreground">
          <DotSpinner />
          {UPDATES_CHECKING}
        </p>
      </div>
    );
  }
  if (
    visible.length === 0 &&
    hidden.length === 0 &&
    warnings.length === 0 &&
    !error
  ) {
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
                disabled={!canApply || updatablePlaces(visible).length === 0}
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
          {error ? (
            <StatusNote
              tone="warning"
              className="mt-3"
              title={UPDATES_UNCONFIRMED_TITLE}
              action={
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
              }
            >
              <span className="flex flex-col gap-1">
                <span>{UPDATES_UNCONFIRMED_BODY}</span>
                <span className="whitespace-pre-wrap text-xs">{error}</span>
              </span>
            </StatusNote>
          ) : null}
          {visible.length === 0 && loaded && !error ? (
            <EmptyState icon={CheckCircle2} title={UPDATES_EMPTY}>
              {UPDATES_EMPTY_BODY}
            </EmptyState>
          ) : null}
          {visible.length > 0 ? (
            <UpdatesTable rows={visible} onIgnore={setConfirmIgnore} />
          ) : null}
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
