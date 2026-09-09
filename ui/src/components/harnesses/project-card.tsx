import type { ReactNode } from "react";
import type { ItemKind } from "@/bindings";
import { Activity } from "@/components/activity";
import { ShowEverythingButton } from "@/components/harnesses/show-everything-button";
import { KindCountBadges } from "@/components/kind-count-badges";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  PLACE_UNCHECKED_LABEL,
  TRY_AGAIN_LABEL,
  unmanagedHereLabel,
} from "@/lib/copy";
import { CHECK_FAILED, CHECKING_PACKAGES } from "@/lib/copy-project-setup";
import { outOfDateHereLabel } from "@/lib/copy-updates";
import { opensLabel, opensOnActivate } from "@/lib/opens-on-activate";

/**
 * One place a setup applies — Personal, or a project folder. Personal and a
 * project are the same kind of thing to a reader, so they get the same card:
 * name and subtitle on top, counts along the bottom, actions on the right.
 * Counts landing in a different place on each would make two identical facts
 * look like two different ones.
 */
export function ProjectCard({
  name,
  subtitle,
  path,
  counts,
  uncounted,
  onOpen,
  onKindClick,
  emptyLabel,
  badge,
  action,
  unmanaged,
  onUnmanaged,
  outOfDate,
  onOutOfDate,
  checking,
  checkFailed,
  onRecheck,
  onAddPackages,
  addPackagesLabel,
  note,
}: {
  name: string;
  subtitle: string;
  /** The folder this card is for, where it has one. The name is only that
   * folder's last segment, which two projects can share, so it is what a
   * label says to name one card apart from another. */
  path?: string;
  counts: [ItemKind, number][];
  /** Why the counts cannot be shown, or null when they can — the badges
   * count packages, and the read that says which installations are one
   * package answers separately from the scan. */
  uncounted?: string | null;
  /** Show everything installed here — what the project's name is a button
   * for. A count badge narrows to one kind, and nothing else on the card
   * asks for everything without picking a kind first. */
  onOpen: () => void;
  onKindClick: (kind: ItemKind) => void;
  emptyLabel: string;
  /** A state worth flagging beside the name, with the reason behind it on
   *  hover. A missing folder is a fault and draws as one; files kendex
   *  wrote and could not offer to commit are not, so the variant travels
   *  with the text rather than being fixed here. */
  badge?: { text: string; variant: "destructive" | "info"; title?: string };
  action?: ReactNode;
  /** How many items here kendex was never asked to look after. Zero says
   *  nothing: this is the one place the app mentions them, and a card
   *  reporting "0 not managed" on every project would be a nag on a page
   *  that is about what is installed. Null where the audit could not read
   *  the place, which is not zero and must not read as it. */
  unmanaged?: number | null;
  onUnmanaged?: () => void;
  /** How many packages installed here have updates. Zero says nothing and
   *  is not drawn; null is a read that has not landed for this place, which
   *  is not zero either. This is what a package's source has moved on to —
   *  never what kendex wrote here and has not committed, which the badge
   *  above says in its own words. */
  outOfDate?: number | null;
  /** Review those updates and take them. */
  onOutOfDate?: () => void;
  /** The read of what is installed here has not answered yet — a project
   *  added a moment ago. Its counts would be empty, which is not the same
   *  as nothing being here, so the card says which state it is in instead
   *  of showing a number it has not got. */
  checking?: boolean;
  /** That read failed. The place is registered either way, so the card
   *  says so and offers the read again rather than drawing an empty
   *  project. */
  checkFailed?: boolean;
  onRecheck?: () => void;
  /** Browse packages to install here. The next step from a place with
   *  nothing in it, offered on the card that says so rather than left for
   *  the reader to find on another page. */
  onAddPackages?: () => void;
  /** What that button says — it names this place, because it is a promise
   *  about where the install lands. */
  addPackagesLabel?: string;
  /** A line about this place that is neither a count nor a fault: the
   *  start-of-session note's standing, with its one button. Under the
   *  counts because it is about the place, not about what is installed. */
  note?: ReactNode;
}) {
  return (
    <Card
      // A shortcut for the pointer and the keyboard alike, on top of the
      // name's own button: the card reads as one target, so clicking its
      // empty space — or pressing Enter on the card — does what the card
      // is for.
      {...opensOnActivate(onOpen, opensLabel(name))}
      className="cursor-pointer gap-3 py-4 hover:bg-accent/40"
    >
      <div className="flex items-start justify-between gap-3 px-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <ShowEverythingButton name={name} path={path} onOpen={onOpen} />
            {badge ? (
              <Badge variant={badge.variant} title={badge.title}>
                {badge.text}
              </Badge>
            ) : null}
          </div>
          <p className="truncate text-[13px] text-muted-foreground">
            {subtitle}
          </p>
        </div>
        {action ? <div className="shrink-0">{action}</div> : null}
      </div>
      <div className="flex flex-wrap items-center gap-1.5 px-4">
        {/* One line at a time, because the three are answers to the same
            question: the read is out, the read failed, or here is what is
            installed. Counts drawn under the first two would be a figure
            for a place nothing has looked at yet, and so would a count of
            what has moved on at its source. */}
        {checking ? (
          <Activity label={CHECKING_PACKAGES} />
        ) : checkFailed ? (
          <>
            <span className="text-[13px] text-muted-foreground">
              {CHECK_FAILED}
            </span>
            {onRecheck ? (
              <Button size="sm" variant="outline" onClick={onRecheck}>
                {TRY_AGAIN_LABEL}
              </Button>
            ) : null}
          </>
        ) : (
          <>
            {/* With nothing installed, the way to install something is the
                empty state rather than a sentence with no way out of it. */}
            {counts.length === 0 && onAddPackages && addPackagesLabel ? (
              <Button size="sm" variant="outline" onClick={onAddPackages}>
                {addPackagesLabel}
              </Button>
            ) : (
              <KindCountBadges
                counts={counts}
                uncounted={uncounted}
                onKindClick={onKindClick}
                emptyLabel={emptyLabel}
                emptyClassName="text-[13px] text-muted-foreground"
              />
            )}
            {/* Sits with the counts because it is one: how much of what is
                at this place kendex is not looking after. The words say
                what the click opens, so the pill is not a number nobody
                can act on. A place that could not be read says so in the
                same slot, as plain text — there is no number, and nothing
                to open. */}
            {unmanaged === null ? (
              <span className="text-[13px] text-muted-foreground">
                {PLACE_UNCHECKED_LABEL}
              </span>
            ) : unmanaged && onUnmanaged ? (
              <button
                type="button"
                onClick={onUnmanaged}
                className="text-[13px] text-muted-foreground underline underline-offset-2 hover:text-foreground"
              >
                {unmanagedHereLabel(unmanaged)}
              </button>
            ) : null}
            {/* In the same slot and for the same reason: how much of what
                is at this place has moved on at its source. The words say
                what the click opens — the changes, before anything is
                written. */}
            {outOfDate && onOutOfDate ? (
              <button
                type="button"
                onClick={onOutOfDate}
                className="text-[13px] text-muted-foreground underline underline-offset-2 hover:text-foreground"
              >
                {outOfDateHereLabel(outOfDate)}
              </button>
            ) : null}
          </>
        )}
      </div>
      {note}
    </Card>
  );
}
