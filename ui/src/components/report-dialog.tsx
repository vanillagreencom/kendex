import { useState } from "react";
import {
  commands,
  type ItemKind,
  type ReportRouteView,
  type Scope,
} from "@/bindings";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";

/** "Report a problem" for one item: shows where the report belongs and
 *  hands over a prefilled issue link when it belongs upstream. */
export function ReportDialog({
  scope,
  name,
  kind,
}: {
  scope: Scope;
  name: string;
  kind: ItemKind;
}) {
  const [open, setOpen] = useState(false);
  const [route, setRoute] = useState<ReportRouteView | null>(null);
  const [copied, setCopied] = useState(false);

  const show = async () => {
    setOpen(true);
    setCopied(false);
    const response = await commands.reportRoute(scope, name, kind);
    setRoute(response.status === "ok" ? response.data : null);
  };

  return (
    <>
      <Button
        size="sm"
        variant="link"
        className="px-0"
        onClick={() => void show()}
      >
        Report a problem…
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Report a problem with {name}</DialogTitle>
            <DialogDescription>
              {route?.issueUrl
                ? "This came from the kendex catalog, so the report goes to the catalog's issue tracker."
                : "This item belongs to your own project, so report it wherever this project tracks its work."}
            </DialogDescription>
          </DialogHeader>
          {route?.issueUrl ? (
            <p className="break-all rounded-md border bg-muted/40 p-3 font-mono text-xs text-muted-foreground">
              {route.issueUrl}
            </p>
          ) : null}
          {route?.warnings.map((warning) => (
            <StatusNote
              key={warning}
              tone="warning"
              title="Routing used fallback evidence"
            >
              {warning}
            </StatusNote>
          ))}
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)}>
              Close
            </Button>
            {route?.issueUrl ? (
              <Button
                onClick={() => {
                  void navigator.clipboard
                    .writeText(route.issueUrl ?? "")
                    .then(() => setCopied(true));
                }}
              >
                {copied ? "Copied" : "Copy link"}
              </Button>
            ) : null}
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
