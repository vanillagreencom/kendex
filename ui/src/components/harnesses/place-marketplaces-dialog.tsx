import { MoreHorizontal } from "lucide-react";
import { useEffect, useState } from "react";
import type { MarketplaceRow, Scope } from "@/bindings";
import { ConfirmDialog } from "@/components/confirm-dialog";
import { UnsubscribeDialog } from "@/components/marketplaces/unsubscribe-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  placeMarketplacesEmpty,
  placeMarketplacesHelp,
  placeMarketplacesReading,
  placeMarketplacesTitle,
  placeMarketplacesUnchecked,
  placeMarketplacesUnconfirmed,
  SWITCHED_OFF_HERE,
  stopUsingLabel,
  TURN_OFF_CONFIRM,
  turnOffBody,
  turnOffLabel,
  turnOffTitle,
  turnOnLabel,
} from "@/lib/copy-model";
import { sameScope } from "@/lib/scope";
import { useMarketplacesStore } from "@/stores/marketplaces";

/** One place's marketplaces, opened from that place's card on Projects.
 *
 * This is where a marketplace is switched off in a place, or dropped from
 * it: both decide what this place installs, so both are read and made here,
 * against one place named in the title. The marketplace's own page lists
 * the places that install from it and changes none of them. */
export function PlaceMarketplacesDialog({
  open,
  onOpenChange,
  scope,
  place,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  scope: Scope;
  /** What this place is called, in the title and in every consequence the
   *  dialog states. */
  place: string;
}) {
  const rows = useMarketplacesStore((s) => s.rows);
  // The read's own outcome, not the store's shared `error`: actions write
  // that field too, and a failed toggle is not a failed overview read.
  const read = useMarketplacesStore((s) => s.read);
  const load = useMarketplacesStore((s) => s.load);
  // Projects does not read marketplaces for its cards, so the list this
  // dialog judges from is fetched when it opens rather than assumed.
  useEffect(() => {
    if (open) void load();
  }, [open, load]);

  const here = rows
    .filter((row) => sameScope(row.scope, scope))
    .sort((a, b) => a.name.localeCompare(b.name));

  // Only a read that landed may say a place installs from nothing. Nothing
  // else in the app reads marketplaces before this dialog asks, so a session
  // that opens Projects first has no rows at all — and the empty sentence
  // over a pending or failed read would deny this place its marketplaces on
  // the one surface that switches one off.
  const said =
    here.length > 0
      ? read.status === "failed"
        ? placeMarketplacesUnconfirmed(place)
        : placeMarketplacesHelp(place)
      : read.status === "pending"
        ? placeMarketplacesReading(place)
        : read.status === "failed"
          ? placeMarketplacesUnchecked(place)
          : placeMarketplacesEmpty(place);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{placeMarketplacesTitle(place)}</DialogTitle>
          <DialogDescription>{said}</DialogDescription>
        </DialogHeader>
        {/* Rows kept from before a failed read stay, headed as what they
            are; with nothing kept, the failure is all there is to show.
            Either way the way out is the same button. */}
        {read.status === "failed" ? (
          <div className="space-y-2">
            <p className="text-sm text-critical" role="alert">
              {read.error}
            </p>
            <Button size="sm" variant="outline" onClick={() => void load()}>
              {TRY_AGAIN_LABEL}
            </Button>
          </div>
        ) : null}
        {here.length === 0 ? null : (
          <div className="divide-y rounded-lg border">
            {here.map((row) => (
              <MarketplaceRowInPlace key={row.name} row={row} place={place} />
            ))}
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}

function MarketplaceRowInPlace({
  row,
  place,
}: {
  row: MarketplaceRow;
  place: string;
}) {
  const toggle = useMarketplacesStore((s) => s.toggle);
  const [turningOff, setTurningOff] = useState(false);
  const [unsubscribing, setUnsubscribing] = useState(false);
  // What the subscription was written as, which is what a reader recognises
  // it by. Absent for a source whose declaration says neither.
  const where = row.repo ?? row.path;

  return (
    <div className="flex items-center gap-3 px-4 py-3">
      <div className="min-w-0 flex-1">
        <p className="truncate text-sm font-medium">{row.name}</p>
        {where ? (
          <p className="truncate font-mono text-xs text-muted-foreground">
            {where}
          </p>
        ) : null}
      </div>
      {row.enabled ? null : (
        <Badge variant="outline" className="shrink-0">
          {SWITCHED_OFF_HERE}
        </Badge>
      )}
      <DropdownMenu>
        <DropdownMenuTrigger
          render={
            <Button
              size="icon-xs"
              variant="quiet"
              aria-label={`More actions for ${row.name}`}
            >
              <MoreHorizontal className="size-4" />
            </Button>
          }
        />
        <DropdownMenuContent align="end">
          {/* Turning it off stops installs that are running and writes to
              the place, so it asks first and says what it costs. Turning it
              back on restores what was there, so it does not. */}
          {row.enabled ? (
            <DropdownMenuItem onClick={() => setTurningOff(true)}>
              {turnOffLabel(row.name)}
            </DropdownMenuItem>
          ) : (
            <DropdownMenuItem
              onClick={() => void toggle(row.scope, row.name, true)}
            >
              {turnOnLabel(row.name)}
            </DropdownMenuItem>
          )}
          <DropdownMenuItem
            className="text-critical"
            onClick={() => setUnsubscribing(true)}
          >
            {stopUsingLabel(row.name)}
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
      <ConfirmDialog
        open={turningOff}
        onOpenChange={setTurningOff}
        title={turnOffTitle(row.name, place)}
        description={turnOffBody(row.name, place)}
        confirmLabel={TURN_OFF_CONFIRM}
        destructive
        onConfirm={() => {
          void toggle(row.scope, row.name, false);
          setTurningOff(false);
        }}
      />
      <UnsubscribeDialog
        open={unsubscribing}
        onOpenChange={setUnsubscribing}
        scope={row.scope}
        source={row.name}
      />
    </div>
  );
}
