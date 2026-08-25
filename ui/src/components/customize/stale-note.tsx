import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";

/** The refusal a stale draft gets, rendered as the choice out of it. The
 *  manifest changed outside this draft — saving the draft would put the
 *  older file back over whatever wrote it — so the one way forward is the
 *  re-read, and taking it discards the edits held here. That cost is the
 *  person's to accept, which is why this is a button and not automatic. */
export function StaleNote({ onReload }: { onReload: () => void }) {
  return (
    <StatusNote
      tone="warning"
      title="This file changed while you were editing"
      action={
        <Button size="sm" variant="outline" onClick={onReload}>
          Reload
        </Button>
      }
    >
      Something else saved kendex.toml — another window, an install, an update.
      Saving this copy would undo that, so it wasn't saved. Reload picks up
      those changes and discards your unsaved edits here.
    </StatusNote>
  );
}
