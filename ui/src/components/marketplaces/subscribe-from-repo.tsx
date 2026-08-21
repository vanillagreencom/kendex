import { useState } from "react";
import { SubscribeDialog } from "@/components/marketplaces/subscribe-dialog";
import { Button } from "@/components/ui/button";

/** The one action a repository page has before anyone subscribes: open
 * the Subscribe dialog with this repository filled in. The dialog is
 * keyed by the repository and mounted only while open, so each opening
 * starts from the prefilled reference rather than a previous attempt's
 * edits. */
export function SubscribeFromRepo({
  repo,
  label,
}: {
  /** The canonical `owner/repo` the page reads, so the subscription keys
   * the same store entry and the page can carry on as it. */
  repo: string;
  label: string;
}) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button size="sm" onClick={() => setOpen(true)}>
        {label}
      </Button>
      {open ? (
        <SubscribeDialog
          key={repo}
          open
          onOpenChange={setOpen}
          initialReference={repo}
        />
      ) : null}
    </>
  );
}
