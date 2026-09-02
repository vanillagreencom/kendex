import { useState } from "react";
import { SubscribeDialog } from "@/components/marketplaces/subscribe-dialog";
import { Button } from "@/components/ui/button";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { SUBSCRIBE_MEANS } from "@/lib/copy-marketplaces";

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
      {/* What subscribing does, on the button that does it — the page
          offers it as its one action, so the explanation has to be here
          and not only inside the dialog it opens. */}
      <Tooltip>
        <TooltipTrigger
          render={
            <Button size="sm" onClick={() => setOpen(true)}>
              {label}
            </Button>
          }
        />
        <TooltipContent className="max-w-72">{SUBSCRIBE_MEANS}</TooltipContent>
      </Tooltip>
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
