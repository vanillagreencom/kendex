import { useState } from "react";
import { FileLink, type Place } from "@/components/file-link";
import { morePlacesLabel } from "@/lib/copy";

/**
 * Every place one finding was found, as files you can open.
 *
 * One is shown and the rest are a click away in the same row: a rule that
 * fired in twenty files would otherwise print a paragraph of paths nobody
 * reads, and a decision that covers twenty files has to say so all the
 * same. Shared, because a surface that shows one place and a surface that
 * shows all of them are telling a person two different things about one
 * decision.
 */
export function FoundAt({ places }: { places: Place[] }) {
  const [expanded, setExpanded] = useState(false);
  const shown = expanded ? places : places.slice(0, 1);
  const hidden = places.length - shown.length;
  return (
    <>
      {shown.map((place) => (
        <FileLink key={`${place.file}:${place.line}`} place={place} />
      ))}
      {hidden > 0 ? (
        <button
          type="button"
          onClick={() => setExpanded(true)}
          className="text-xs text-muted-foreground underline underline-offset-2 hover:text-foreground"
        >
          {morePlacesLabel(hidden)}
        </button>
      ) : null}
    </>
  );
}
