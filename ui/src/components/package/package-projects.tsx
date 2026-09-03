import type { ItemKind, Scope } from "@/bindings";
import { ProjectCard } from "@/components/package/project-card";
import { usePackagePlaces } from "@/components/package/use-package-places";
import { Section } from "@/components/section";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import {
  PROJECTS_EMPTY,
  PROJECTS_HEADING,
  PROJECTS_LOADING,
  REMOVE_ALL_LABEL,
  UPDATE_ALL_LABEL,
} from "@/lib/copy-projects";
import { removablePlaces, updatableRows } from "@/lib/package-places";
import { scopeKey } from "@/lib/scope";
import { useAuditStore } from "@/stores/audit";
import { useUpdatesStore } from "@/stores/updates";

/** One card per place, while the places are still being read. Two, because
 *  a single bar reads as a row that failed to load rather than as a list
 *  arriving. */
function ProjectsSkeleton() {
  return (
    <div
      role="status"
      aria-label={PROJECTS_LOADING}
      className="flex flex-col gap-3"
    >
      <Skeleton className="h-[4.5rem] w-full" />
      <Skeleton className="h-[4.5rem] w-full" />
    </div>
  );
}

/** The package page's Projects tab: every place this package is installed
 *  in, one card each, with the update and the removal that reach that
 *  place alone. Deleting every copy is not offered per card — it is one
 *  decision about the package, so it goes through the dialog `onDelete`
 *  opens. */
export function PackageProjects({
  kind,
  name,
  scopes,
  busy,
  onDelete,
}: {
  kind: ItemKind;
  name: string;
  scopes: Scope[];
  busy: boolean;
  onDelete: () => void;
}) {
  const { places, loading, removalHeld } = usePackagePlaces(kind, name, scopes);
  const updateOne = useUpdatesStore((s) => s.updateOne);
  const updateRows = useUpdatesStore((s) => s.updateRows);
  const removeItem = useAuditStore((s) => s.removeItem);
  const waiting = updatableRows(places);
  const removable = removablePlaces(places);

  return (
    <Section
      title={PROJECTS_HEADING}
      action={
        loading || places.length === 0 ? null : (
          <span className="flex items-center gap-4">
            {waiting.length > 0 ? (
              <Button
                variant="link"
                size="sm"
                className="px-0"
                disabled={busy}
                onClick={() => void updateRows(waiting)}
              >
                {UPDATE_ALL_LABEL}
              </Button>
            ) : null}
            {/* Held to the same judge as the cards: with nothing here
                kendex owns, there is no removal for this link to ask
                for. */}
            {removable.length > 0 ? (
              <Button
                variant="link"
                size="sm"
                className="px-0"
                disabled={busy || removalHeld}
                onClick={onDelete}
              >
                {REMOVE_ALL_LABEL}
              </Button>
            ) : null}
          </span>
        )
      }
    >
      {loading ? (
        <ProjectsSkeleton />
      ) : places.length === 0 ? (
        <p className="text-sm text-muted-foreground">{PROJECTS_EMPTY}</p>
      ) : (
        <div className="flex flex-col gap-3">
          {places.map((place) => (
            <ProjectCard
              key={scopeKey(place.scope)}
              place={place}
              busy={busy}
              removalHeld={removalHeld}
              onUpdate={() => place.row && void updateOne(place.row)}
              onRemove={() => void removeItem(place.scope, kind, name)}
            />
          ))}
        </div>
      )}
    </Section>
  );
}
