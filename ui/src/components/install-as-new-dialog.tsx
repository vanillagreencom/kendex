import { useId, useState } from "react";
import type { HarnessId, UpdateRow } from "@/bindings";
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
  INSTALL_AS_NEW_LABEL,
  installAsNewBody,
  installAsNewTitle,
  OWN_COPY_NAME_LABEL,
  ownCopyDefaultName,
} from "@/lib/copy-updates";
import { packageDisplayName } from "@/lib/labels";
import { useUpdatesStore } from "@/stores/updates";
import { installAsNew } from "@/stores/updates-edits";

/** The one question installing beside an edited copy asks: what to call
 *  the copy. The newest version takes the name the package always had, so
 *  the edited files need one of their own. A refusal from the engine — the
 *  name is taken, or nothing can be kept — shows here, under the field it
 *  is about. Mounted only while open, so each opening starts clean. */
export function InstallAsNewDialog({
  row,
  harness,
  onOpenChange,
}: {
  row: UpdateRow;
  harness: HarnessId;
  onOpenChange: (open: boolean) => void;
}) {
  const busy = useUpdatesStore((s) => s.busy);
  const fieldId = useId();
  const [own, setOwn] = useState(ownCopyDefaultName(row.name));
  const [error, setError] = useState<string | null>(null);
  const name = packageDisplayName(row);
  const trimmed = own.trim();

  const submit = () => {
    if (trimmed === "") return;
    // The callback lands at the engine's answer, not at the reads behind
    // it: the refusal is what the person retypes over, so it must not wait
    // out a machine-wide scan. The promise covers those reads, and nothing
    // here needs them — `busy` is what keeps the buttons down until they
    // land.
    void installAsNew(row, harness, trimmed, (failure) => {
      if (failure === null) onOpenChange(false);
      else setError(failure);
    });
  };

  return (
    <Dialog open onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{installAsNewTitle(name)}</DialogTitle>
          <DialogDescription>{installAsNewBody(name)}</DialogDescription>
        </DialogHeader>
        <form
          className="space-y-3"
          onSubmit={(event) => {
            event.preventDefault();
            submit();
          }}
        >
          <div className="space-y-1.5">
            <Label htmlFor={fieldId}>{OWN_COPY_NAME_LABEL}</Label>
            <Input
              id={fieldId}
              value={own}
              onChange={(event) => {
                setOwn(event.target.value);
                setError(null);
              }}
              autoFocus
            />
            {error ? (
              <p className="text-sm text-critical" role="alert">
                {error}
              </p>
            ) : null}
          </div>
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={busy}
              onClick={() => onOpenChange(false)}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={busy || trimmed === ""}>
              {INSTALL_AS_NEW_LABEL}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
