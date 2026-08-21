import { Button } from "@/components/ui/button";
import { SAVE_NOTE } from "@/lib/copy-customize";

export function SaveBar({
  saving,
  busy = false,
  onSave,
  onDiscard,
}: {
  saving: boolean;
  /** Another rewrite of the same manifest is in flight: a save landing
   *  on top of it would carry a draft that no longer matches the file. */
  busy?: boolean;
  onSave: () => void;
  onDiscard: () => void;
}) {
  return (
    <div className="sticky bottom-0 flex items-center gap-3 border-t bg-background/95 px-8 py-3 backdrop-blur">
      <span className="text-sm text-muted-foreground">{SAVE_NOTE}</span>
      <span className="flex-1" />
      <Button
        variant="ghost"
        size="sm"
        disabled={saving || busy}
        onClick={onDiscard}
      >
        Discard
      </Button>
      <Button size="sm" disabled={saving || busy} onClick={onSave}>
        {saving ? "Saving…" : "Save and apply"}
      </Button>
    </div>
  );
}
