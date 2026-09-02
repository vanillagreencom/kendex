import type { UnreadableScope } from "@/bindings";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { SEE_PROBLEMS_LABEL } from "@/lib/copy-marketplaces";
import {
  UPDATES_UNREADABLE_TITLE,
  unreadableProjectsLabel,
} from "@/lib/copy-updates";
import { scopeName } from "@/lib/labels";
import { useNavStore } from "@/stores/nav";

/** One project kendex cannot read is not a machine-wide failure: every
 * other project's rows stand. The note names the projects with no standing
 * and sends the reader to Problems, which carries the reason and the way
 * out. */
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
      {unreadableProjectsLabel(places.map((place) => scopeName(place.scope)))}
    </StatusNote>
  );
}
