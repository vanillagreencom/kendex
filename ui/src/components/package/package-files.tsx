import { useState } from "react";
import type { ItemKind, PackageFile, Scope } from "@/bindings";
import { FileBrowser } from "@/components/files/file-browser";
import type { FileEntry } from "@/components/files/file-tree-model";
import { FilePreview } from "@/components/package/file-preview";
import { StatusNote } from "@/components/status-note";
import { Button } from "@/components/ui/button";
import { README_TAG, TRY_AGAIN_LABEL } from "@/lib/copy";
import {
  FILE_TREE_LABEL,
  fileSizeLabel,
  NO_FILES_NOTE,
} from "@/lib/copy-files";

/** The package's Files tab: its tree on the left, the file you picked on
 *  the right, across the width of the page. Opens on the readme, which is
 *  what `FilePreview` shows for a null path. */
export function PackageFiles({
  scope,
  kind,
  name,
  files,
  note,
  retryRunning,
  onRetry,
}: {
  scope: Scope;
  kind: ItemKind;
  name: string;
  files: PackageFile[];
  /** Why there are no files to list, where the read did not land:
   *  `package-read-state.ts` [`packageFilesNote`]. Null while the read is
   *  pending or once it landed, and a landed read with nothing in it is a
   *  package that ships no files. */
  note: string | null;
  /** Whether the page's reads are out again. The note stays put while they
   *  run — it is still the last answer — so the button is what says the
   *  page is doing something about it. */
  retryRunning: boolean;
  onRetry: () => void;
}) {
  const [chosen, setChosen] = useState<string | null>(null);

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
  if (files.length === 0) {
    return <p className="text-sm text-muted-foreground">{NO_FILES_NOTE}</p>;
  }
  // The tab opens on the readme, so the row that holds it says so: a pane
  // showing a file no row is marked as leaves the reader hunting for where
  // it came from.
  const entries: FileEntry[] = files.map((file) => ({
    path: file.path,
    meta: file.isReadme ? (
      <>
        {README_TAG} {fileSizeLabel(file.size)}
      </>
    ) : (
      fileSizeLabel(file.size)
    ),
  }));
  return (
    <FileBrowser
      entries={entries}
      selected={chosen}
      onSelect={setChosen}
      label={FILE_TREE_LABEL}
    >
      <FilePreview scope={scope} kind={kind} name={name} path={chosen} />
    </FileBrowser>
  );
}
