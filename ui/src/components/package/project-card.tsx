import { useEffect, useRef } from "react";
import { SetupRow, shownState } from "@/components/package/setup-row";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { UPDATE_LABEL } from "@/lib/copy";
import {
  installedAgo,
  REMOVE_LABEL,
  removeFromLabel,
  updateInLabel,
} from "@/lib/copy-projects";
import { scopePath } from "@/lib/labels";
import { opensLabel, opensOnActivate } from "@/lib/opens-on-activate";
import type { PackagePlace } from "@/lib/package-places";
import { exactTime } from "@/lib/relative-time";
import { useNowTick } from "@/lib/use-now-tick";
import { cn } from "@/lib/utils";
import type { SetupEntry } from "@/stores/package-setup";

/** One place this package is installed in: what the place is called, when
 *  this copy landed there, and the two things you can do to that copy
 *  alone. A card, not a settings row, because it is one object a person
 *  acts on as a unit. */
export function ProjectCard({
  place,
  busy,
  removalHeld,
  focused,
  setup,
  onOpen,
  onUpdate,
  onRemove,
  onSetUp,
  onCheckAgain,
}: {
  place: PackagePlace;
  busy: boolean;
  /** The Overview's setup summary sent the reader to this card. Marked
   *  and scrolled to once, so the link lands on the row it named. */
  focused: boolean;
  /** This place's setup answer, or null where this package changes
   *  nothing about the repository and there is no setup to report. */
  setup: SetupEntry | null;
  /** Open this place — everything installed there, not only this
   *  package. The card names a place, so the card opens it. */
  onOpen: () => void;
  /** The ownership answer under Remove is not current. The button stays
   *  where it is and goes dead, rather than leaving the row as the read
   *  behind a write comes and goes under a reader's cursor. */
  removalHeld: boolean;
  onUpdate: () => void;
  onRemove: () => void;
  /** Run the package's declared setup here, through the same
   *  repository-changes dialog an install asks through. */
  onSetUp: () => void;
  onCheckAgain: () => void;
}) {
  // On the shared tick, not the render: a tab left open would otherwise
  // keep saying a copy was installed just now hours after it was.
  const now = useNowTick();
  // Two facts on one line, and the line is dropped rather than padded when
  // neither read answered: an install date the record does not carry is
  // not a date to guess at, and the personal scope has no path to print.
  const detail = [installedAgo(place.installedAt, now), scopePath(place.scope)]
    .filter((part) => part !== null)
    .join(" · ");

  const card = useRef<HTMLDivElement>(null);
  // Once, when the card becomes the one that was pointed at. A scroll on
  // every render would drag the tab back here while somebody is reading
  // another card.
  useEffect(() => {
    if (focused) card.current?.scrollIntoView({ block: "nearest" });
  }, [focused]);

  return (
    <Card
      ref={card}
      {...opensOnActivate(onOpen, opensLabel(place.name))}
      className={cn(
        "cursor-pointer flex-col items-stretch gap-0 px-5 py-4 hover:bg-accent/40",
        focused && "ring-2 ring-ring",
      )}
    >
      <div className="flex flex-row items-center justify-between gap-4">
        <div className="min-w-0">
          {/* What a screen reader is told opens the place: a card announces
            its content rather than an action. */}
          <button
            type="button"
            onClick={onOpen}
            className="block max-w-full truncate text-left text-sm font-medium hover:underline"
          >
            {place.name}
          </button>
          {detail ? (
            <p
              className="mt-0.5 truncate text-[13px] text-muted-foreground"
              title={
                place.installedAt
                  ? exactTime(Date.parse(place.installedAt))
                  : undefined
              }
            >
              {detail}
            </p>
          ) : null}
        </div>
        <div className="flex shrink-0 items-center gap-2">
          {/* Offered only where the update can actually be taken here — a
            button the engine would refuse is worse than no button. */}
          {place.updatable ? (
            <Button
              size="sm"
              disabled={busy}
              aria-label={updateInLabel(place.name)}
              onClick={onUpdate}
            >
              {UPDATE_LABEL}
            </Button>
          ) : null}
          {/* Same rule as Update: offered only where the engine can take
            it. kendex removes what it declares and what its lock owns, so
            a copy it merely observed, or one the tool ships itself, has no
            Remove — the click would leave this card exactly where it is. */}
          {place.removable ? (
            <Button
              size="sm"
              variant="outline"
              disabled={busy || removalHeld}
              aria-label={removeFromLabel(place.name)}
              onClick={onRemove}
            >
              {REMOVE_LABEL}
            </Button>
          ) : null}
        </div>
      </div>
      {/* Installed and set up are two facts, so they are two lines. A
          package that changes nothing about the repository has no second
          line at all. The row's own buttons answer their own clicks —
          `clickAsksToOpen` stands every real control down — so nothing
          here has to stop the card opening the place. */}
      {setup ? (
        <SetupRow
          place={place.name}
          setup={setup.setup}
          refused={setup.refused}
          state={shownState(setup)}
          busy={busy}
          onActivate={onSetUp}
          onRepair={onSetUp}
          onCheckAgain={onCheckAgain}
        />
      ) : null}
    </Card>
  );
}
