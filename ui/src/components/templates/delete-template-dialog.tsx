import { useEffect } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  DELETE_BODY,
  DELETE_CONFIRM,
  DELETE_TITLE,
} from "@/lib/copy-templates";
import { useNavStore } from "@/stores/nav";
import { useTemplatesStore } from "@/stores/templates";

/** Deleting a template. The title names it, and the body says the one
 *  thing a person needs to know before pressing: what was installed from
 *  it stays installed. */
export function DeleteTemplateDialog({
  name,
  open,
  onOpenChange,
}: {
  name: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const remove = useTemplatesStore((s) => s.remove);
  const busy = useTemplatesStore((s) => s.busy);
  const refused = useTemplatesStore((s) => s.refused);
  const clearRefusal = useTemplatesStore((s) => s.clearRefusal);
  const goToLibrary = useNavStore((s) => s.goToLibrary);

  useEffect(() => {
    if (open) clearRefusal();
  }, [open, clearRefusal]);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{DELETE_TITLE(name)}</DialogTitle>
          <DialogDescription>{DELETE_BODY}</DialogDescription>
        </DialogHeader>
        {refused ? (
          <p className="text-[13px] text-critical">{refused}</p>
        ) : null}
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            variant="destructive"
            disabled={busy}
            onClick={() =>
              void remove(name).then((ok) => {
                if (!ok) return;
                onOpenChange(false);
                goToLibrary();
              })
            }
          >
            {DELETE_CONFIRM}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
