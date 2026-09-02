import { useState } from "react";
import type { UpdateRow } from "@/bindings";
import { InstallAsNewDialog } from "@/components/install-as-new-dialog";
import { Button } from "@/components/ui/button";
import {
  INSTALL_AS_NEW_LABEL,
  UPDATE_NEEDS_CHECK_NOTE,
} from "@/lib/copy-updates";

/** Whether the engine-projected row permits installing beside an edit. */
export const installableBeside = (row: UpdateRow): boolean =>
  row.forkableHarness !== null &&
  row.updateAvailable &&
  !row.removedUpstream &&
  row.canDiscard;

/** The edited place's one way to a newer version: beside the edits, never
 *  over them. The install may move a hold to the row's `latest`, so it
 *  waits for a check the same as Update. */
export function InstallAsNew({
  row,
  busy,
  held,
}: {
  row: UpdateRow;
  busy: boolean;
  held: boolean;
}) {
  const [open, setOpen] = useState(false);
  const harness = row.forkableHarness;
  if (!harness) return null;
  return (
    <>
      <Button
        size="sm"
        variant="outline"
        disabled={busy || held}
        title={held ? UPDATE_NEEDS_CHECK_NOTE : undefined}
        onClick={() => setOpen(true)}
      >
        {INSTALL_AS_NEW_LABEL}
      </Button>
      {open ? (
        <InstallAsNewDialog
          row={row}
          harness={harness}
          onOpenChange={setOpen}
        />
      ) : null}
    </>
  );
}
