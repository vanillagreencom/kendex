import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";

/** The refusal a stale draft gets, rendered as the choice out of it. The
 *  file a draft came from changed outside it — saving would put the older
 *  copy back over whatever wrote it — so the one way forward is the
 *  re-read, and taking it discards the edits held here. That cost is the
 *  person's to accept, which is why this is a button and not automatic.
 *
 *  It names no file. Either draft this tab holds can be the one refused,
 *  the manifest or the settings, and the refusal does not say which — so
 *  naming one would send a person to look at a file that may not have
 *  moved, in the sentence they read before discarding what they typed. */
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
      The file this draft came from changed after you opened it. Saving would
      put the older copy back, so nothing was saved. Reload takes the file as it
      is now and discards your unsaved edits here.
    </StatusNote>
  );
}
