import type { ItemSource } from "@/bindings";
import { FilePane } from "@/components/files/file-pane";
import { StatusNote } from "@/components/status-note";
import { Skeleton } from "@/components/ui/skeleton";
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
}: {
  /** The README the last landed read found, or null where the package
   *  carries none. */
  readme: ItemSource | null;
  read: ReadState;
}) {
  if (read.status === "failed" && read.error !== null) {
    return (
      <StatusNote tone="critical" title={FILE_READ_FAILED_TITLE}>
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
