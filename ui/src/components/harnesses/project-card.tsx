import type { ReactNode } from "react";
import type { ItemKind } from "@/bindings";
import { KindCountBadges } from "@/components/kind-count-badges";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";

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
  counts,
  onOpen,
  onKindClick,
  emptyLabel,
  badge,
  action,
}: {
  name: string;
  subtitle: string;
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
}) {
  return (
    <Card
      // A shortcut for the mouse, on top of the name's own button: the card
      // reads as one target, so clicking its empty space should do what the
      // card is for. Every control inside it means something else and has
      // already answered the click; a drag that ends here was someone
      // keeping the path, not asking to leave the page.
      onClick={(event) => {
        if ((event.target as HTMLElement).closest("button")) return;
        if (window.getSelection()?.isCollapsed === false) return;
        onOpen();
      }}
      className="cursor-pointer gap-3 py-4 hover:bg-accent/40"
    >
      <div className="flex items-start justify-between gap-3 px-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <button
              type="button"
              onClick={onOpen}
              aria-label={`Show everything in ${name}`}
              className="truncate text-sm font-medium hover:underline"
            >
              {name}
            </button>
            {badge ? <Badge variant="destructive">{badge}</Badge> : null}
          </div>
          <p className="truncate text-[13px] text-muted-foreground">
            {subtitle}
          </p>
        </div>
        {action ? <div className="shrink-0">{action}</div> : null}
      </div>
      <div className="flex flex-wrap gap-1.5 px-4">
        <KindCountBadges
          counts={counts}
          onKindClick={onKindClick}
          emptyLabel={emptyLabel}
          emptyClassName="text-[13px] text-muted-foreground"
        />
      </div>
    </Card>
  );
}
