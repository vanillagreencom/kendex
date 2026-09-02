import type { UnreadableScope } from "@/bindings";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { SEE_PROBLEMS_LABEL } from "@/lib/copy-marketplaces";
import {
  UPDATES_UNREADABLE_TITLE,
  unreadablePlaceLine,
} from "@/lib/copy-updates";
import { scopeLabel } from "@/lib/derive";
import { scopeNames } from "@/lib/labels";
import { useNavStore } from "@/stores/nav";

/** One place kendex cannot read is not a machine-wide failure: every
 * other place's rows stand. The note names each place with no standing
 * beside the reason the read gave, and sends the reader to Problems, which
 * carries the typed cause and the way out. The personal scope has a lock
 * of its own and lands here as "Personal", which is why these are places
 * rather than projects. */
export function UnreadablePlacesNote({
  places,
}: {
  places: UnreadableScope[];
}) {
  const goTo = useNavStore((s) => s.goTo);
  const names = scopeNames(places.map((place) => place.scope));
  if (places.length === 0) return null;
  return (
    <StatusNote
      tone="warning"
      title={UPDATES_UNREADABLE_TITLE}
      className="mb-6"
      action={
        <Button size="sm" variant="outline" onClick={() => goTo("problems")}>
          {SEE_PROBLEMS_LABEL}
        </Button>
      }
    >
      <ul className="space-y-0.5">
        {places.map((place, index) => (
          <li key={scopeLabel(place.scope)}>
            {unreadablePlaceLine(names[index] ?? "", place.message)}
          </li>
        ))}
      </ul>
    </StatusNote>
  );
}
