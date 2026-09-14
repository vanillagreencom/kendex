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
import {
  REPORT_PROBLEM_LABEL,
  REPORT_TO_MARKETPLACE,
  REPORT_TO_PROJECT,
  REPORT_UNSURE_TITLE,
  reportProblemTitle,
} from "@/lib/copy";

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
        {REPORT_PROBLEM_LABEL}
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{reportProblemTitle(name)}</DialogTitle>
            <DialogDescription>
              {route?.issueUrl ? REPORT_TO_MARKETPLACE : REPORT_TO_PROJECT}
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
              title={REPORT_UNSURE_TITLE}
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
