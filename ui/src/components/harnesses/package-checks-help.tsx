import { Info } from "lucide-react";
import { useState } from "react";
import type { HarnessId } from "@/bindings";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  CHECKS_QUIET,
  CHECKS_REMOVE,
  CHECKS_WHAT,
  CHECKS_WHEN,
  checksHarnesses,
  HELP_INSTALLS_NOTHING,
  PACKAGE_CHECKS_HELP_LABEL,
  PACKAGE_CHECKS_HELP_TITLE,
  PACKAGE_CHECKS_PURPOSE,
} from "@/lib/copy-package-checks";

/** What the checks are, beside the label that names them — for a reader
 *  deciding whether to switch them on, and for one who already has and
 *  wants to know what is running.
 *
 *  A button, so a pointer and a keyboard reach the same panel; there is no
 *  hover-only route to it. It reads and nothing else: no action of any
 *  kind is on this panel, so opening it can install nothing.
 *
 *  Its sentences are the confirmation's own, from `copy-package-checks`,
 *  so the explanation a person reads before the ask and the one they read
 *  afterwards cannot drift apart. */
export function PackageChecksHelp({
  harnesses,
}: {
  harnesses: readonly HarnessId[];
}) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button
        variant="ghost"
        size="icon-xs"
        aria-label={PACKAGE_CHECKS_HELP_LABEL}
        title={PACKAGE_CHECKS_HELP_LABEL}
        onClick={() => setOpen(true)}
      >
        <Info className="size-4" />
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{PACKAGE_CHECKS_HELP_TITLE}</DialogTitle>
            <DialogDescription>{PACKAGE_CHECKS_PURPOSE}</DialogDescription>
          </DialogHeader>
          <div className="flex flex-col gap-2 text-[13px] text-muted-foreground">
            <p>{CHECKS_WHAT}</p>
            <p>{CHECKS_WHEN}</p>
            <p>{CHECKS_QUIET}</p>
            {harnesses.length > 0 ? <p>{checksHarnesses(harnesses)}</p> : null}
            <p>{CHECKS_REMOVE}</p>
            <p>{HELP_INSTALLS_NOTHING}</p>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
