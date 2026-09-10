import { X } from "lucide-react";
import type { ReactNode } from "react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogClose,
  DialogDescription,
  DialogPanel,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  CHANGES_TITLE,
  CLOSE_CHANGES_LABEL,
  comparing,
} from "@/lib/copy-files";

/** A change being inspected, drawn as a full-height panel that slides in
 *  over whatever asked for it.
 *
 *  A comparison is not a page and it is not a step: the surface behind it —
 *  the package page's tab, the commit dialog's list — is still what the
 *  reader is doing, and closing the panel puts them back on it with
 *  nothing moved. Full height because a diff is read down the screen, and
 *  a box in the middle of the window would show a dozen lines of it. */
export function ChangesPanel({
  open,
  onClose,
  fromLabel,
  toLabel,
  children,
}: {
  open: boolean;
  onClose: () => void;
  /** The two sides, named the way the surface that opened this names
   *  them — a version, "installed", "your edits in Claude Code". */
  fromLabel: string;
  toLabel: string;
  children: ReactNode;
}) {
  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) onClose();
      }}
    >
      <DialogPanel>
        <div className="flex shrink-0 items-baseline gap-3 border-b px-5 py-3">
          <DialogTitle className="text-[15px] font-semibold tracking-tight">
            {CHANGES_TITLE}
          </DialogTitle>
          <DialogDescription className="min-w-0 truncate">
            {comparing(fromLabel, toLabel)}
          </DialogDescription>
          <DialogClose
            render={
              <Button
                variant="ghost"
                size="icon-sm"
                className="ml-auto self-center"
                aria-label={CLOSE_CHANGES_LABEL}
              >
                <X className="size-4" />
              </Button>
            }
          />
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto px-5 py-4">
          {children}
        </div>
      </DialogPanel>
    </Dialog>
  );
}
