import type { ReactNode } from "react";
import type { ItemKind } from "@/bindings";
import { ShowEverythingButton } from "@/components/harnesses/show-everything-button";
import { KindCountBadges } from "@/components/kind-count-badges";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { clickAsksToOpen } from "@/lib/click-asks-to-open";
import { unmanagedHereLabel } from "@/lib/copy";

/**
 * One place a setup applies — Personal, or a project folder. Personal and a
 * project are the same kind of thing to a reader, so they get the same card:
 * name and subtitle on top, counts along the bottom, actions on the right.
 * They used to differ, and the counts landing in a different place each time
 * made two identical facts look like two different ones.
 */
export function ProjectCard({
  name,
  subtitle,
  path,
  counts,
  onOpen,
  onKindClick,
  emptyLabel,
  badge,
  action,
  unmanaged,
  onUnmanaged,
}: {
  name: string;
  subtitle: string;
  /** The folder this card is for, where it has one. The name is only that
   * folder's last segment, which two projects can share, so it is what a
   * label says to name one card apart from another. */
  path?: string;
  counts: [ItemKind, number][];
  /** Show everything installed here — what the project's name is a button
   * for. A count badge narrows to one kind, and there was no way to ask for
   * everything without picking a kind first. */
  onOpen: () => void;
  onKindClick: (kind: ItemKind) => void;
  emptyLabel: string;
  /** A state worth flagging beside the name, e.g. a missing folder. */
  badge?: string;
  action?: ReactNode;
  /** How many items here kendex was never asked to look after. Zero says
   *  nothing: this is the one place the app mentions them, and a card
   *  reporting "0 not managed" on every project would be a nag on a page
   *  that is about what is installed. */
  unmanaged?: number;
  onUnmanaged?: () => void;
}) {
  return (
    <Card
      // A shortcut for the mouse, on top of the name's own button: the card
      // reads as one target, so clicking its empty space should do what the
      // card is for.
      onClick={(event) => {
        if (clickAsksToOpen(event)) onOpen();
      }}
      className="cursor-pointer gap-3 py-4 hover:bg-accent/40"
    >
      <div className="flex items-start justify-between gap-3 px-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <ShowEverythingButton name={name} path={path} onOpen={onOpen} />
            {badge ? <Badge variant="destructive">{badge}</Badge> : null}
          </div>
          <p className="truncate text-[13px] text-muted-foreground">
            {subtitle}
          </p>
        </div>
        {action ? <div className="shrink-0">{action}</div> : null}
      </div>
      <div className="flex flex-wrap items-center gap-1.5 px-4">
        <KindCountBadges
          counts={counts}
          onKindClick={onKindClick}
          emptyLabel={emptyLabel}
          emptyClassName="text-[13px] text-muted-foreground"
        />
        {/* Sits with the counts because it is one: how much of what is at
            this place kendex is not looking after. The words say what the
            click opens, so the pill is not a number nobody can act on. */}
        {unmanaged && onUnmanaged ? (
          <button
            type="button"
            onClick={onUnmanaged}
            className="text-[13px] text-muted-foreground underline underline-offset-2 hover:text-foreground"
          >
            {unmanagedHereLabel(unmanaged)}
          </button>
        ) : null}
      </div>
    </Card>
  );
}
