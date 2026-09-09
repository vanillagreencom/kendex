import type { ItemKind } from "@/bindings";
import { Badge } from "@/components/ui/badge";
import { kindLabel } from "@/lib/labels";

/** A row of item-kind count pills — clickable when a handler is given,
 *  falling back to an empty-state message when there's nothing to show. */
export function KindCountBadges({
  counts,
  uncounted,
  onKindClick,
  describe,
  emptyLabel = "Nothing yet",
  emptyClassName = "text-xs text-muted-foreground",
}: {
  counts: [ItemKind, number][];
  /** Why there is no count to show, or null when there is one. It outranks
   *  the counts and the empty label alike: a read that has not answered has
   *  not found nothing, and a number drawn from it would be counting
   *  something other than what the badge says. */
  uncounted?: string | null;
  onKindClick?: (kind: ItemKind) => void;
  /** What pressing one of these badges does, in words. "3 skills" says what
   *  the badge counts and nothing about where the press lands; a caller that
   *  can name the place says it here and the pill announces it. */
  describe?: (kind: ItemKind, count: number) => string;
  emptyLabel?: string;
  emptyClassName?: string;
}) {
  if (uncounted) {
    return <span className={emptyClassName}>{uncounted}</span>;
  }
  if (counts.length === 0) {
    return <span className={emptyClassName}>{emptyLabel}</span>;
  }
  return (
    <>
      {counts.map(([kind, count]) =>
        onKindClick ? (
          <Badge
            key={kind}
            variant="outline"
            className="cursor-pointer hover:bg-accent"
            render={
              <button
                type="button"
                aria-label={describe?.(kind, count)}
                onClick={() => onKindClick(kind)}
              >
                {count} {kindLabel(kind, count)}
              </button>
            }
          />
        ) : (
          <Badge key={kind} variant="outline">
            {count} {kindLabel(kind, count)}
          </Badge>
        ),
      )}
    </>
  );
}
