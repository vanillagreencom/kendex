import { useEffect, useState } from "react";
import type { Scope } from "@/bindings";
import { templateSubject } from "@/components/templates/template-subject";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { INSTALL_ACTION } from "@/lib/copy-install";
import {
  BROWSE_PACKAGES_LABEL,
  INSTALL_TEMPLATE_TITLE,
  NO_TEMPLATES_TO_INSTALL,
  PICK_TEMPLATE_LABEL,
  TEMPLATES_EXPLAINER,
} from "@/lib/copy-templates";
import { useInstallFlow } from "@/stores/install-flow";
import { useNavStore } from "@/stores/nav";
import { useTemplatesStore } from "@/stores/templates";

/** Pick a saved selection to install into one place, then hand it to the
 *  guided install, which asks where and which tools exactly as it does for
 *  a package. This dialog answers only which template. */
export function InstallTemplateDialog({
  into,
  open,
  onOpenChange,
}: {
  /** The place this was opened on behalf of, so the guided install opens
   *  on it rather than asking again. */
  into: Scope;
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const templates = useTemplatesStore((s) => s.templates);
  const load = useTemplatesStore((s) => s.load);
  const openInstall = useInstallFlow((s) => s.open);
  const goToMarketplaces = useNavStore((s) => s.goToMarketplaces);
  const [picked, setPicked] = useState("");

  useEffect(() => {
    if (open) void load();
  }, [open, load]);
  useEffect(() => {
    if (open) setPicked(templates[0]?.name ?? "");
  }, [open, templates]);

  const chosen = templates.find((one) => one.name === picked) ?? null;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{INSTALL_TEMPLATE_TITLE}</DialogTitle>
          <DialogDescription>
            {templates.length === 0
              ? NO_TEMPLATES_TO_INSTALL
              : TEMPLATES_EXPLAINER}
          </DialogDescription>
        </DialogHeader>
        {templates.length > 0 ? (
          <div className="flex flex-col gap-2">
            <Label htmlFor="template-install-pick">{PICK_TEMPLATE_LABEL}</Label>
            <Select
              value={picked}
              onValueChange={(value) => setPicked(value ?? "")}
            >
              <SelectTrigger id="template-install-pick">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {templates.map((template) => (
                  <SelectItem key={template.name} value={template.name}>
                    {template.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        ) : null}
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          {templates.length === 0 ? (
            <Button
              onClick={() => {
                onOpenChange(false);
                goToMarketplaces("packages", into);
              }}
            >
              {BROWSE_PACKAGES_LABEL}
            </Button>
          ) : (
            <Button
              disabled={chosen === null}
              onClick={() => {
                if (!chosen) return;
                onOpenChange(false);
                // The place travels with the browse, so the guided install
                // opens on it rather than asking where again.
                useNavStore.setState({ installInto: into });
                openInstall({ subjects: [templateSubject(chosen)] });
              }}
            >
              {INSTALL_ACTION}
            </Button>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
