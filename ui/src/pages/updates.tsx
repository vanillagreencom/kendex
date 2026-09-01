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
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { updatesBeforeList } from "@/components/updates-before-list";
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
  lastCheckedLabel,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATES_ONE_AT_A_TIME_NOTE,
  UPDATES_UNCONFIRMED_TITLE,
  updatesSubtitle,
} from "@/lib/copy-updates";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import {
  hiddenUpdates,
  packageCount,
  updatablePlaces,
  visibleUpdates,
} from "@/lib/update-groups";
import { rowUnsettled } from "@/lib/updates-read-state";
import { useNowTick } from "@/lib/use-now-tick";
import { cn } from "@/lib/utils";
import { useAuditOnMount } from "@/stores/audit";
import { useUpdatesStore } from "@/stores/updates";
import { useUpdatesView } from "@/stores/updates-view";

/** Which packages have newer versions, what changed, and per-package
 *  control over how loudly to hear about it. */
export function UpdatesPage() {
  const { rows, warnings, busy, checking, check, updateRows } =
    useUpdatesStore();
  const read = useUpdatesStore((s) => s.read);
  // Update all holds on exactly what it would act on, so the button and
  // updateRows answer to one predicate: any visible row about to be
  // replaced, by an overview-producing read or by a flip settling in its
  // scope.
  const unconfirmed = useUpdatesStore((s) =>
    visibleUpdates(s.rows).some((row) => rowUnsettled(s, row)),
  );
  const load = useUpdatesStore((s) => s.reload);
  const lastFetched = useUpdatesStore((s) => s.lastFetched);
  // One choice for every table on the page; the `…` menu lives on the
  // main table, or on the muted one when it is the only table drawn.
  const setShowVersion = useUpdatesView((s) => s.setShowVersion);
  const [showHidden, setShowHidden] = useState(false);
  const [confirmIgnore, setConfirmIgnore] = useState<UpdateRow | null>(null);

  useEffect(() => {
    void load();
  }, [load]);
  // The rows carry the score of what is installed now, which is the audit's
  // answer, not the update check's.
  useAuditOnMount();

  const visible = visibleUpdates(rows);
  const hidden = hiddenUpdates(rows);
  const HiddenChevron = showHidden ? ChevronDown : ChevronRight;
  const empty =
    visible.length === 0 && hidden.length === 0 && warnings.length === 0;

  // On the page's own clock, not the render's. Only a read of the standing
  // re-renders this — mount, a check, a mutation — so a window left open
  // would go on claiming the age it had when it opened.
  const now = useNowTick();
  const lastChecked = lastCheckedLabel(lastFetched, now);

  const beforeList = updatesBeforeList({
    read,
    empty,
    checking,
    busy,
    lastChecked,
    onCheck: () => void check(),
  });
  if (beforeList) return beforeList;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <PageHeader
        title="Updates"
        wide
        subtitle={
          <>
            {visible.length > 0 ? (
              <p>{updatesSubtitle(packageCount(visible), visible.length)}</p>
            ) : null}
            <p className="text-xs">{lastChecked}</p>
          </>
        }
        action={
          <div className="flex gap-2">
            {/* A failed check always leaves its retry reachable: with no
                visible rows but hidden ones or warnings keeping the page
                on, this button is the only way to try again. */}
            {visible.length > 0 || read.error !== null ? (
              <Button
                size="sm"
                variant="outline"
                disabled={checking || busy}
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
                disabled={
                  busy || unconfirmed || updatablePlaces(visible).length === 0
                }
                title={unconfirmed ? UPDATE_NEEDS_CHECK_NOTE : undefined}
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
          {/* Rows kept from before a failed check stay on screen — right —
              but headed as what they are: the last read that answered, not
              the current standing. */}
          {read.error !== null ? (
            <StatusNote
              tone="warning"
              title={UPDATES_UNCONFIRMED_TITLE}
              className="mb-6"
            >
              {read.error}
            </StatusNote>
          ) : null}
          {visible.length === 0 ? (
            read.error === null ? (
              <EmptyState icon={CheckCircle2} title={UPDATES_EMPTY}>
                {UPDATES_EMPTY_BODY}
              </EmptyState>
            ) : null
          ) : (
            <UpdatesTable
              rows={visible}
              onIgnore={setConfirmIgnore}
              onShowVersion={setShowVersion}
            />
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
                  <UpdatesTable
                    rows={hidden}
                    onShowVersion={
                      visible.length === 0 ? setShowVersion : undefined
                    }
                  />
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
        confirmDisabled={busy || checking}
        confirmDisabledNote={UPDATES_ONE_AT_A_TIME_NOTE}
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
