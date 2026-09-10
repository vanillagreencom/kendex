import type { ItemSource } from "@/bindings";
import { FilePane } from "@/components/files/file-pane";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import { FILE_READ_FAILED_TITLE, NO_README_NOTE } from "@/lib/copy-files";
import type { ReadState } from "@/lib/read-state";

/** The package's own words about itself, and nothing else.
 *
 *  The Overview is the README, so a package that carries none says so.
 *  Falling back to whichever file happens to be first would put an
 *  arbitrary source file under the package's details, where a reader would
 *  take it for the package describing itself. Its files are a tab of their
 *  own, where picking one is the reader's own act.
 *
 *  The read is the page's, not this component's: an update or a version
 *  switch replaces the installed copy without moving the address, and a
 *  read of its own keyed on the package would go on showing the words of
 *  the copy that was replaced. */
export function PackageReadme({
  readme,
  read,
  retryRunning,
  onRetry,
}: {
  /** The README the last landed read found, or null where the package
   *  carries none. */
  readme: ItemSource | null;
  read: ReadState;
  /** Whether the page's reads are out again, which is what disables the
   *  button while the answer under it is being asked for. */
  retryRunning: boolean;
  onRetry: () => void;
}) {
  if (read.status === "failed" && read.error !== null) {
    // A read that failed is offered again where it failed, the way every
    // other failed read on this page is: without it a transient refusal
    // leaves the Overview holding an error until the page is left.
    return (
      <StatusNote
        tone="critical"
        title={FILE_READ_FAILED_TITLE}
        action={
          <Button
            size="sm"
            variant="outline"
            disabled={retryRunning}
            onClick={onRetry}
          >
            {TRY_AGAIN_LABEL}
          </Button>
        }
      >
        {read.error}
      </StatusNote>
    );
  }
  if (read.status === "pending") {
    return (
      <div className="space-y-2">
        <Skeleton className="h-3.5 w-3/4" />
        <Skeleton className="h-3.5 w-full" />
        <Skeleton className="h-3.5 w-5/6" />
      </div>
    );
  }
  if (readme === null) {
    return <p className="text-sm text-muted-foreground">{NO_README_NOTE}</p>;
  }
  return <FilePane {...readme} />;
}
