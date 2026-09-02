import type { UnreadableScope } from "@/bindings";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { SEE_PROBLEMS_LABEL } from "@/lib/copy-marketplaces";
import {
  UPDATES_UNREADABLE_TITLE,
  unreadableProjectLine,
} from "@/lib/copy-updates";
import { scopeLabel } from "@/lib/derive";
import { scopeName } from "@/lib/labels";
import { useNavStore } from "@/stores/nav";

/** One project kendex cannot read is not a machine-wide failure: every
 * other project's rows stand. The note names each project with no standing
 * beside the reason the read gave, and sends the reader to Problems, which
 * carries the typed cause and the way out. */
export function UnreadableProjectsNote({
  places,
}: {
  places: UnreadableScope[];
}) {
  const goTo = useNavStore((s) => s.goTo);
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
        {places.map((place) => (
          <li key={scopeLabel(place.scope)}>
            {unreadableProjectLine(scopeName(place.scope), place.message)}
          </li>
        ))}
      </ul>
    </StatusNote>
  );
}
