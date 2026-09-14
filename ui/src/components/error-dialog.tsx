import { CLASS_TONES } from "@/components/home/attention-rows";
import { STATUS_TONES } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { useProblemsStore } from "@/stores/problems";

/** The one modal for a failed user action, rendered once in App.tsx —
 *  every store's failure path calls showError instead of owning dialog
 *  markup of its own. */
export function ErrorDialog() {
  const { open, title, message, steps, actions } = useProblemsStore(
    (s) => s.dialog,
  );
  const closeError = useProblemsStore((s) => s.closeError);

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) closeError();
      }}
    >
      <DialogContent>
        <DialogHeader>
          <DialogTitle className={STATUS_TONES[CLASS_TONES.failed].text}>
            {title}
          </DialogTitle>
        </DialogHeader>
        {message ? (
          <p className="break-words rounded-md bg-muted/50 p-2 font-mono text-xs text-muted-foreground">
            {message}
          </p>
        ) : null}
        {steps.length > 0 ? (
          <ul className="list-disc space-y-1 pl-5 text-sm text-muted-foreground">
            {steps.map((step) => (
              <li key={step}>{step}</li>
            ))}
          </ul>
        ) : null}
        <DialogFooter>
          {actions.map((action) => (
            <Button
              key={action.label}
              variant="outline"
              onClick={() => {
                closeError();
                action.onClick();
              }}
            >
              {action.label}
            </Button>
          ))}
          <Button onClick={closeError}>OK</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
