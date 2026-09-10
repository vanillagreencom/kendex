import { useEffect, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  ADD_TO_TEMPLATE_HELP,
  ADD_TO_TEMPLATE_TITLE,
  addedToTemplate,
  droppedFromTemplate,
  NEW_TEMPLATE_OPTION,
  PICK_TEMPLATE_LABEL,
  TEMPLATE_NAME_LABEL,
} from "@/lib/copy-templates";
import type { Saveable } from "@/lib/template-members";
import { useTemplatesStore } from "@/stores/templates";

/** The value the picker holds while the answer is "a new one". Not a
 *  template name: a template really called this would be picked by
 *  accident, and the picker's own options are the only other values. */
const NEW = " new";

/** Save selected packages into a template — an existing one, or one named
 *  here. Install stays the primary action wherever this is offered; this
 *  is the selection's secondary one. */
export function AddToTemplateDialog({
  saveable,
  open,
  onOpenChange,
}: {
  /** The packages to save, and the ticked rows no template can record. */
  saveable: Saveable;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const { members, dropped } = saveable;
  const templates = useTemplatesStore((s) => s.templates);
  const load = useTemplatesStore((s) => s.load);
  const addMembers = useTemplatesStore((s) => s.addMembers);
  const createFromSelection = useTemplatesStore((s) => s.createFromSelection);
  const busy = useTemplatesStore((s) => s.busy);
  const refused = useTemplatesStore((s) => s.refused);
  const clearRefusal = useTemplatesStore((s) => s.clearRefusal);
  const [picked, setPicked] = useState<string>(NEW);
  const [name, setName] = useState("");

  useEffect(() => {
    if (!open) return;
    clearRefusal();
    setName("");
    void load();
  }, [open, load, clearRefusal]);

  // Opening on the first template a person has is the answer they most
  // often want; with none, the only answer is a new one.
  useEffect(() => {
    if (open) setPicked(templates[0]?.name ?? NEW);
  }, [open, templates]);

  const target = picked === NEW ? name.trim() : picked;
  const submit = () => {
    const saving =
      picked === NEW
        ? createFromSelection(target, members)
        : addMembers(picked, members);
    void saving.then((ok) => {
      if (!ok) return;
      onOpenChange(false);
      toast.success(addedToTemplate(members.length, target));
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{ADD_TO_TEMPLATE_TITLE}</DialogTitle>
          <DialogDescription>{ADD_TO_TEMPLATE_HELP}</DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-4">
          <div className="flex flex-col gap-2">
            <Label htmlFor="template-pick">{PICK_TEMPLATE_LABEL}</Label>
            <Select
              value={picked}
              onValueChange={(value) => setPicked(value ?? NEW)}
            >
              <SelectTrigger id="template-pick">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {templates.map((template) => (
                  <SelectItem key={template.name} value={template.name}>
                    {template.name}
                  </SelectItem>
                ))}
                <SelectItem value={NEW}>{NEW_TEMPLATE_OPTION}</SelectItem>
              </SelectContent>
            </Select>
          </div>
          {picked === NEW ? (
            <div className="flex flex-col gap-2">
              <Label htmlFor="template-new-name">{TEMPLATE_NAME_LABEL}</Label>
              <Input
                id="template-new-name"
                value={name}
                onChange={(event) => setName(event.target.value)}
              />
            </div>
          ) : null}
          {/* The rows that cannot be recorded, named before the save
              rather than silently missing from the count afterwards. */}
          {dropped.length > 0 ? (
            <p className="text-[13px] text-muted-foreground">
              {droppedFromTemplate(dropped)}
            </p>
          ) : null}
          {refused ? (
            <p className="text-[13px] text-critical">{refused}</p>
          ) : null}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            disabled={busy || target === "" || members.length === 0}
            onClick={submit}
          >
            Save
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
