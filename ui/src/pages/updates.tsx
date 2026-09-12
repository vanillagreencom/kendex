import { ChevronDown, ChevronRight, RefreshCw } from "lucide-react";
import { useEffect, useState } from "react";
import type { Scope, UpdateRow } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { PageHeader } from "@/components/page-header";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { UpdateReviewDialog } from "@/components/updates/update-review-dialog";
import { updatesBeforeList } from "@/components/updates-before-list";
import { UpdatesTable } from "@/components/updates-table";
import { UnreadablePlacesNote } from "@/components/updates-unreadable-note";
import {
  CHECK_FOR_UPDATES_LABEL,
  hiddenUpdatesLabel,
  IGNORE_CONFIRM_BODY,
  IGNORE_CONFIRM_LABEL,
  ignoreConfirmTitle,
  UPDATE_ALL_LABEL,
  UPDATES_UNCHECKED_TITLE,
} from "@/lib/copy";
import {
  lastCheckedLabel,
  UPDATE_MENU_LABEL,
  UPDATE_NEEDS_CHECK_NOTE,
  UPDATE_ONE_PLACE_HEADING,
  UPDATES_ONE_AT_A_TIME_NOTE,
  UPDATES_UNCONFIRMED_TITLE,
  updateEverythingItem,
  updatePlaceItem,
  updatesSubtitle,
} from "@/lib/copy-updates";
import { PAGE_GUTTER, WIDE_CONTENT_WIDTH } from "@/lib/layout";
import { exactTime } from "@/lib/relative-time";
import { scopeKey } from "@/lib/scope";
import {
  hiddenUpdates,
  packageCount,
  placeCount,
  placeKey,
  placeName,
  placesWithUpdates,
  updatablePlaces,
  visibleUpdates,
} from "@/lib/update-groups";
import { emptyStanding, readUnsettled } from "@/lib/updates-read-state";
import { useNowTick } from "@/lib/use-now-tick";
import { cn } from "@/lib/utils";
import { useAuditOnMount } from "@/stores/audit";
import { useNavStore } from "@/stores/nav";
import { useUpdatesStore } from "@/stores/updates";
import { useUpdatesView } from "@/stores/updates-view";

/** Which packages have newer versions, what changed, and per-package
 *  control over how loudly to hear about it. */
export function UpdatesPage() {
  const { rows, warnings, busy, checking, check, updateRows } =
    useUpdatesStore();
  const read = useUpdatesStore((s) => s.read);
  const unreadable = useUpdatesStore((s) => s.unreadable);
  // The page's update control holds on exactly what the store refuses on,
  // so the button and `updateRows` answer to one predicate: rows an
  // overview-producing read is about to replace.
  const unconfirmed = useUpdatesStore(readUnsettled);
  const load = useUpdatesStore((s) => s.reload);
  const lastFetched = useUpdatesStore((s) => s.lastFetched);
  // One choice for every table on the page; the `…` menu lives on the
  // main table, or on the muted one when it is the only table drawn.
  const setShowVersion = useUpdatesView((s) => s.setShowVersion);
  const goToMarketplaces = useNavStore((s) => s.goToMarketplaces);
  const [showHidden, setShowHidden] = useState(false);
  const [confirmIgnore, setConfirmIgnore] = useState<UpdateRow | null>(null);
  // WHICH places an update was asked for, never the rows themselves, and
  // what the place is called where the ask named one. Held here rather than
  // per row so one dialog stands behind every Update on the page, whatever
  // its scope.
  //
  // Keys, because a read landing under an open dialog replaces every row:
  // a captured array would leave the diff on screen and the commit behind
  // the button answering to a standing the app has already moved past. The
  // rows are looked up again on every render, the way a place's card does
  // it, so the dialog reads what the store has now.
  const [review, setReview] = useState<{
    places: string[];
    among: Scope[];
    place: string | null;
  } | null>(null);

  useEffect(() => {
    void load();
  }, [load]);
  // The rows carry the score of what is installed now, which is the audit's
  // answer, not the update check's.
  useAuditOnMount();

  const visible = visibleUpdates(rows);
  const hidden = hiddenUpdates(rows);
  const wanted = new Set(review?.places ?? []);
  const reviewRows = review
    ? rows.filter((row) => wanted.has(placeKey(row)))
    : [];
  const HiddenChevron = showHidden ? ChevronDown : ChevronRight;
  const empty =
    visible.length === 0 &&
    hidden.length === 0 &&
    warnings.length === 0 &&
    unreadable.length === 0;

  // On the page's own clock, not the render's. Only a read of the standing
  // re-renders this — mount, a check, a mutation — so a window left open
  // would go on claiming the age it had when it opened.
  const now = useNowTick();
  const lastChecked = lastCheckedLabel(lastFetched, now);

  const beforeList = updatesBeforeList({
    read,
    standing: emptyStanding(rows, lastFetched),
    empty,
    checking,
    busy,
    lastChecked,
    onCheck: () => void check(),
    onBrowse: () => goToMarketplaces(),
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
              <p>
                {updatesSubtitle(packageCount(visible), placeCount(visible))}
              </p>
            ) : null}
            <p
              className="text-xs"
              title={lastFetched ? exactTime(lastFetched * 1000) : undefined}
            >
              {lastChecked}
            </p>
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
              <UpdateAction
                visible={visible}
                held={busy || unconfirmed}
                heldNote={unconfirmed ? UPDATE_NEEDS_CHECK_NOTE : undefined}
                onReview={(picked, place) =>
                  setReview({
                    places: picked.map(placeKey),
                    // Every place on the page, so two projects ending in
                    // one folder name read apart in the confirm that
                    // writes their files.
                    among: visible.map((row) => row.scope),
                    place,
                  })
                }
              />
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
          <UnreadablePlacesNote places={unreadable} />
          {/* Nothing is drawn where the list is empty: this branch is
              reached only with hidden rows, warnings or unreadable places
              keeping the page on, and each of those draws itself below.
              An up-to-date claim over muted updates or a place nobody
              could read is the contradiction `updatesBeforeList` answers,
              and only it may make that claim. */}
          {visible.length === 0 ? null : (
            <UpdatesTable
              rows={visible}
              onIgnore={setConfirmIgnore}
              onShowVersion={setShowVersion}
              onUpdate={(picked, place, among) =>
                setReview({
                  places: picked.map(placeKey),
                  among,
                  place,
                })
              }
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
      <UpdateReviewDialog
        rows={reviewRows}
        among={review?.among ?? []}
        place={review?.place ?? null}
        open={review !== null}
        onOpenChange={(open) => {
          if (!open) setReview(null);
        }}
        busy={busy}
        held={unconfirmed}
        onConfirm={(picked) => {
          setReview(null);
          void updateRows(picked);
        }}
      />
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

/** The page's own way into the update flow. Where one place holds every
 *  update on screen there is one thing to ask for and it is a button;
 *  where several do, the page offers each place's worth beside everything,
 *  because "update this project's packages" is a decision a person makes
 *  and the table's rows are grouped by package, not by place.
 *
 *  Both routes open the same review, so the three scopes — one package,
 *  one place, everything — are one flow and not three. */
function UpdateAction({
  visible,
  held,
  heldNote,
  onReview,
}: {
  visible: UpdateRow[];
  /** Nothing on this page may be acted on right now. */
  held: boolean;
  heldNote?: string;
  onReview: (rows: UpdateRow[], place: string | null) => void;
}) {
  const places = placesWithUpdates(visible);
  const nothing = updatablePlaces(visible).length === 0;
  if (places.length < 2) {
    return (
      <Button
        size="sm"
        disabled={held || nothing}
        title={heldNote}
        onClick={() => onReview(visible, null)}
      >
        {UPDATE_ALL_LABEL}
      </Button>
    );
  }
  const scopes = places.map((place) => place.scope);
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <Button size="sm" disabled={held || nothing} title={heldNote}>
            {UPDATE_MENU_LABEL}
          </Button>
        }
      />
      <DropdownMenuContent align="end">
        <DropdownMenuItem onClick={() => onReview(visible, null)}>
          {updateEverythingItem(packageCount(updatablePlaces(visible)))}
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <p className="px-2 py-1.5 text-xs text-muted-foreground">
          {UPDATE_ONE_PLACE_HEADING}
        </p>
        {places.map((place) => {
          const name = placeName(place.scope, scopes);
          return (
            <DropdownMenuItem
              key={scopeKey(place.scope)}
              onClick={() => onReview(place.rows, name)}
            >
              {updatePlaceItem(name, packageCount(updatablePlaces(place.rows)))}
            </DropdownMenuItem>
          );
        })}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
