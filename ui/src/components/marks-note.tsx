import { RefreshCw } from "lucide-react";
import { toast } from "sonner";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { backgroundReadFailed, CHECK_FOR_UPDATES_LABEL } from "@/lib/copy";
import {
  MARKS_UNREAD_MANIFESTS,
  MARKS_UNREAD_TITLE,
  MARKS_UNREAD_UPDATES,
} from "@/lib/copy-customize";
import { cn } from "@/lib/utils";
import { useEditorStore } from "@/stores/editor";
import { whyUnread } from "@/stores/editor-order";
import { useUpdatesStore } from "@/stores/updates";

/** Said out loud when a read behind the per-place marks failed. Without it
 *  a failed read renders as a table of packages with nothing marked, which
 *  reads as "nothing of yours is here" — the one thing it does not mean.
 *  It belongs on every surface the marks reach, not only the Library: the
 *  Customize chips draw the same conclusion from the same two reads. */
export function MarksNote({ className }: { className?: string }) {
  const updatesError = useUpdatesStore((s) => s.error);
  const checking = useUpdatesStore((s) => s.checking);
  const check = useUpdatesStore((s) => s.check);
  // Derived from the reads themselves, so the note cannot outlive the
  // failure: the last place to read again takes this away with it.
  const manifestError = useEditorStore(whyUnread);
  const reading = useEditorStore((s) => s.manifestsReading);
  const loadAll = useEditorStore((s) => s.loadAll);
  if (!updatesError && !manifestError) return null;
  return (
    <StatusNote
      tone="warning"
      title={MARKS_UNREAD_TITLE}
      className={cn("mb-3", className)}
      action={
        <Button
          size="sm"
          variant="outline"
          disabled={checking || reading}
          onClick={() => {
            // The retry says whether it worked: a rejection dropped here
            // would leave this very note as the only sign anything ran.
            const said = (thrown: unknown) =>
              toast.error(backgroundReadFailed(String(thrown)));
            void check().catch(said);
            void loadAll().catch(said);
          }}
        >
          <RefreshCw
            className={cn("size-3.5", (checking || reading) && "animate-spin")}
          />
          {CHECK_FOR_UPDATES_LABEL}
        </Button>
      }
    >
      <span className="flex flex-col gap-1">
        {updatesError ? <span>{MARKS_UNREAD_UPDATES}</span> : null}
        {manifestError ? <span>{MARKS_UNREAD_MANIFESTS}</span> : null}
        <span className="whitespace-pre-wrap text-xs">
          {[updatesError, manifestError].filter(Boolean).join("\n")}
        </span>
      </span>
    </StatusNote>
  );
}
