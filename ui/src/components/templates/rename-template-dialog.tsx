import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { RENAME_TITLE, TEMPLATE_NAME_LABEL } from "@/lib/copy-templates";
import { useNavStore } from "@/stores/nav";
import { useTemplatesStore } from "@/stores/templates";

/** Give a template another name. Nothing it installs changes, and neither
 *  do the copies it owns — the store is keyed by what the create reserved,
 *  not by the name. */
export function RenameTemplateDialog({
  name,
  open,
  onOpenChange,
}: {
  name: string;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const rename = useTemplatesStore((s) => s.rename);
  const busy = useTemplatesStore((s) => s.busy);
  const refused = useTemplatesStore((s) => s.refused);
  const clearRefusal = useTemplatesStore((s) => s.clearRefusal);
  const goToTemplate = useNavStore((s) => s.goToTemplate);
  const [wanted, setWanted] = useState(name);

  useEffect(() => {
    if (open) {
      setWanted(name);
      clearRefusal();
    }
  }, [open, name, clearRefusal]);

  const submit = () => {
    void rename(name, wanted).then((ok) => {
      if (!ok) return;
      onOpenChange(false);
      goToTemplate(wanted.trim());
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{RENAME_TITLE}</DialogTitle>
        </DialogHeader>
        <div className="flex flex-col gap-2">
          <Label htmlFor="template-rename">{TEMPLATE_NAME_LABEL}</Label>
          <Input
            id="template-rename"
            value={wanted}
            onChange={(event) => setWanted(event.target.value)}
          />
          {refused ? (
            <p className="text-[13px] text-critical">{refused}</p>
          ) : null}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button disabled={busy || wanted.trim() === ""} onClick={submit}>
            Rename
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
