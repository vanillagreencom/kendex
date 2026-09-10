import { useState } from "react";
import type { ItemKind, PackageFile, Scope } from "@/bindings";
import { FileBrowser } from "@/components/files/file-browser";
import { packageFileEntries } from "@/components/files/package-file-rows";
import { DotSpinner } from "@/components/loading";
import { FilePreview } from "@/components/package/file-preview";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  FILE_TREE_LABEL,
  FILES_READING_NOTE,
  NO_FILES_NOTE,
} from "@/lib/copy-files";
import { packageFilesNote } from "@/lib/package-read-state";
import type { ReadState } from "@/lib/read-state";

/** The package's Files tab: its tree on the left, the file you picked on
 *  the right, across the width of the page. Opens on the readme, which is
 *  what `FilePreview` shows for a null path. */
export function PackageFiles({
  scope,
  kind,
  name,
  files,
  read,
  retryRunning,
  onRetry,
}: {
  scope: Scope;
  kind: ItemKind;
  name: string;
  files: PackageFile[];
  /** How the read that found these files went. The tab renders off the
   *  read's own state and not off the empty list alone: a first read still
   *  on its way leaves the same empty list as a landed one, and only a
   *  landed read may say the package ships no files. */
  read: ReadState;
  /** Whether the page's reads are out again. The note stays put while they
   *  run — it is still the last answer — so the button is what says the
   *  page is doing something about it. */
  retryRunning: boolean;
  onRetry: () => void;
}) {
  const [chosen, setChosen] = useState<string | null>(null);

  const note = packageFilesNote(read);
  if (note !== null) {
    // The note already carries the headline and the reason the read came
    // back with; the button beside it is what the page can do about it.
    return (
      <StatusNote
        tone="critical"
        title={note}
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
      />
    );
  }
  if (read.status === "pending") {
    return (
      <p className="flex items-center gap-2 text-sm text-muted-foreground">
        <DotSpinner />
        {FILES_READING_NOTE}
      </p>
    );
  }
  if (files.length === 0) {
    return <p className="text-sm text-muted-foreground">{NO_FILES_NOTE}</p>;
  }
  return (
    <FileBrowser
      entries={packageFileEntries(files)}
      selected={chosen}
      onSelect={setChosen}
      label={FILE_TREE_LABEL}
    >
      <FilePreview scope={scope} kind={kind} name={name} path={chosen} />
    </FileBrowser>
  );
}
