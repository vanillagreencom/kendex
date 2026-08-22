import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  openLocationLabel,
  UNSAVED_ELSEWHERE_BODY,
  UNSAVED_ELSEWHERE_TITLE,
} from "@/lib/copy-customize";
import { scopeKey } from "@/lib/scope";
import { useEditorStore } from "@/stores/editor";
import { named } from "@/stores/editor-scopes";
import { useNavStore } from "@/stores/nav";

/** Typing parked at a place the editor has moved away from, said out loud
 *  with the way back to it. A draft that survives the move but that nobody
 *  can see is the same loss one step later — this is what makes carrying it
 *  worth more than asking. */
export function UnsavedElsewhere({ className }: { className?: string }) {
  const held = useEditorStore((s) => s.held);
  const saving = useEditorStore((s) => s.saving);
  const setScope = useEditorStore((s) => s.setScope);
  const goTo = useNavStore((s) => s.goTo);
  const waiting = Object.values(held);
  if (waiting.length === 0) return null;
  return (
    <StatusNote
      tone="info"
      title={UNSAVED_ELSEWHERE_TITLE}
      className={className}
    >
      <span className="flex flex-col items-start gap-2">
        <span>{UNSAVED_ELSEWHERE_BODY}</span>
        <span className="flex flex-wrap gap-2">
          {waiting.map((place) => (
            <Button
              key={scopeKey(place.scope)}
              size="sm"
              variant="outline"
              // Switching place mid-save would attribute the outcome to a
              // place it is not about, the same gate the chips carry.
              disabled={saving}
              onClick={() => {
                // The Customize page, not wherever this is rendered: a
                // draft is a whole manifest, and that page shows all of one
                // for a place. A package page can only show the slice of it
                // that names that package, which for a package not
                // installed there is nothing at all.
                goTo("customize");
                void setScope(place.scope);
              }}
            >
              {openLocationLabel(named(place.scope))}
            </Button>
          ))}
        </span>
      </span>
    </StatusNote>
  );
}
