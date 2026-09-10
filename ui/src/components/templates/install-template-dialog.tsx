import { useEffect, useRef, useState } from "react";
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
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import { INSTALL_ACTION } from "@/lib/copy-install";
import {
  BROWSE_PACKAGES_LABEL,
  INSTALL_TEMPLATE_TITLE,
  NO_TEMPLATES_TO_INSTALL,
  PICK_TEMPLATE_LABEL,
  TEMPLATES_EXPLAINER,
  TEMPLATES_LAST_KNOWN,
  TEMPLATES_READING,
  TEMPLATES_UNREADABLE,
} from "@/lib/copy-templates";
import { useInstallFlow } from "@/stores/install-flow";
import { useNavStore } from "@/stores/nav";
import {
  type Template,
  useTemplatesAnswer,
  useTemplatesStore,
} from "@/stores/templates";

/** The rows an answer with none has, as one value rather than a fresh
 *  array per render. */
const NO_TEMPLATES: Template[] = [];

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
  const answer = useTemplatesAnswer();
  const load = useTemplatesStore((s) => s.load);
  const openInstall = useInstallFlow((s) => s.open);
  const goToMarketplaces = useNavStore((s) => s.goToMarketplaces);
  const [picked, setPicked] = useState("");

  // The rows this answer has. A wait and an unreadable index have none,
  // and neither of them is a person with no templates: the sentence that
  // says so, and the Browse packages button beside it, are drawn only from
  // a read that answered.
  const templates =
    answer.shown === "waiting" || answer.shown === "unreadable"
      ? NO_TEMPLATES
      : answer.templates;
  const failure =
    answer.shown === "unreadable"
      ? TEMPLATES_UNREADABLE
      : answer.shown === "lastKnown"
        ? TEMPLATES_LAST_KNOWN
        : null;

  useEffect(() => {
    if (open) void load();
  }, [open, load]);
  // Which open this is. The picker is initialized for a new open and left
  // alone by the refresh that open started: a dialog with rows already
  // cached is one a person can choose in while that read is still out, and
  // resetting on every change of the list replaced their choice with the
  // first row the moment it landed — the save then went somewhere they had
  // not picked, with nothing on screen saying it had moved.
  //
  // Not initialized until there is something to initialize from, so a
  // dialog opened before the first read lands still takes the first row
  // when the rows arrive. After that the choice is theirs, and only a
  // refreshed list that no longer holds it takes it away.
  const initialized = useRef(false);
  useEffect(() => {
    if (!open) {
      initialized.current = false;
      return;
    }
    const first = templates[0]?.name ?? "";
    if (!initialized.current) {
      setPicked(first);
      initialized.current = templates.length > 0;
      return;
    }
    setPicked((current) =>
      templates.some((one) => one.name === current) ? current : first,
    );
  }, [open, templates]);

  const chosen = templates.find((one) => one.name === picked) ?? null;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{INSTALL_TEMPLATE_TITLE}</DialogTitle>
          <DialogDescription>
            {answer.shown === "waiting"
              ? TEMPLATES_READING
              : failure !== null
                ? failure
                : templates.length === 0
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
          {/* A read that failed is offered again rather than answered for:
              sending somebody to browse packages over it would be acting
              on a library kendex has not read. */}
          {failure !== null ? (
            <Button variant="outline" onClick={() => void load()}>
              {TRY_AGAIN_LABEL}
            </Button>
          ) : null}
          {/* Rows to install from, or a read that answered and found none
              — and nothing at all while a read is out or one failed with
              nothing behind it, where neither answer is known. */}
          {templates.length > 0 ? (
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
          ) : answer.shown === "read" ? (
            <Button
              onClick={() => {
                onOpenChange(false);
                goToMarketplaces("packages", into);
              }}
            >
              {BROWSE_PACKAGES_LABEL}
            </Button>
          ) : null}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
