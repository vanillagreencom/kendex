import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { UPDATE_LABEL } from "@/lib/copy";
import { installedAgo, REMOVE_LABEL } from "@/lib/copy-projects";
import { scopePath } from "@/lib/labels";
import type { PackagePlace } from "@/lib/package-places";

/** One place this package is installed in: what the place is called, when
 *  this copy landed there, and the two things you can do to that copy
 *  alone. A card, not a settings row, because it is one object a person
 *  acts on as a unit. */
export function ProjectCard({
  place,
  busy,
  onUpdate,
  onRemove,
}: {
  place: PackagePlace;
  busy: boolean;
  onUpdate: () => void;
  onRemove: () => void;
}) {
  // Two facts on one line, and the line is dropped rather than padded when
  // neither read answered: an install date the record does not carry is
  // not a date to guess at, and the personal scope has no path to print.
  const detail = [
    installedAgo(place.installedAt, Date.now()),
    scopePath(place.scope),
  ]
    .filter((part) => part !== null)
    .join(" · ");

  return (
    <Card className="flex-row items-center justify-between gap-4 px-5 py-4">
      <div className="min-w-0">
        <p className="truncate text-sm font-medium">{place.name}</p>
        {detail ? (
          <p className="mt-0.5 truncate text-[13px] text-muted-foreground">
            {detail}
          </p>
        ) : null}
      </div>
      <div className="flex shrink-0 items-center gap-2">
        {/* Offered only where the update can actually be taken here — a
            button the engine would refuse is worse than no button. */}
        {place.updatable ? (
          <Button size="sm" disabled={busy} onClick={onUpdate}>
            {UPDATE_LABEL}
          </Button>
        ) : null}
        <Button size="sm" variant="outline" disabled={busy} onClick={onRemove}>
          {REMOVE_LABEL}
        </Button>
      </div>
    </Card>
  );
}
