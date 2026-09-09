import { useEffect, useState } from "react";
import type { PackageDiff } from "@/bindings";
import { DiffPane } from "@/components/files/diff-pane";
import { FileBrowser } from "@/components/files/file-browser";
import type { FileEntry } from "@/components/files/file-tree-model";
import { DotSpinner } from "@/components/loading";
import { DIFF_TRUNCATED_NOTE } from "@/lib/copy";
import {
  CHANGED_FILES_TREE_LABEL,
  COMPARING_NOTE,
  NO_CHANGES_NOTE,
  PICK_A_CHANGE_NOTE,
} from "@/lib/copy-files";
import { additionsLabel, deletionsLabel, lineNumberWidth } from "@/lib/diff";

/** A whole comparison, in the app's one file layout: the changed files as
 *  a tree on the left, the chosen file's diff on the right. Serves version
 *  comparison, update previews and the "what did I change" view — the same
 *  shape everywhere, and the same shape as reading a package's files. */
export function ChangesViewer({ diff }: { diff: PackageDiff | null }) {
  const [chosen, setChosen] = useState<string | null>(null);
  // A new comparison is a new set of files, and a path from the one before
  // it names nothing here. Falling back to the first file rather than to
  // nothing: a reader who opened a comparison came to read a change.
  useEffect(() => {
    setChosen(diff?.files[0]?.path ?? null);
  }, [diff]);

  if (!diff) {
    return (
      <p className="flex items-center gap-2 text-sm text-muted-foreground">
        <DotSpinner />
        {COMPARING_NOTE}
      </p>
    );
  }
  if (diff.files.length === 0) {
    return <p className="text-sm text-muted-foreground">{NO_CHANGES_NOTE}</p>;
  }
  const gutterCh = lineNumberWidth(diff);
  const entries: FileEntry[] = diff.files.map((file) => ({
    path: file.path,
    meta: <Counts additions={file.additions} deletions={file.deletions} />,
  }));
  const file = diff.files.find((one) => one.path === chosen) ?? null;
  return (
    <div className="flex min-h-0 flex-col gap-4">
      <div className="flex items-baseline gap-3">
        {diff.truncated ? (
          <p className="text-xs text-muted-foreground">{DIFF_TRUNCATED_NOTE}</p>
        ) : null}
        <span className="ml-auto">
          <Counts
            additions={diff.totalAdditions}
            deletions={diff.totalDeletions}
          />
        </span>
      </div>
      <FileBrowser
        entries={entries}
        selected={chosen}
        onSelect={setChosen}
        label={CHANGED_FILES_TREE_LABEL}
      >
        <DiffPane file={file} gutterCh={gutterCh} note={PICK_A_CHANGE_NOTE} />
      </FileBrowser>
    </div>
  );
}

/** `+12 −3`, the pair a row and a total both carry. Either half is drawn
 *  only where it happened: a file that only gained lines showing `−0`
 *  invites a reader to look for a deletion that is not there. */
function Counts({
  additions,
  deletions,
}: {
  additions: number;
  deletions: number;
}) {
  return (
    <span className="inline-flex gap-2 font-mono tabular-nums">
      {additions > 0 ? (
        <span className="text-good">{additionsLabel(additions)}</span>
      ) : null}
      {deletions > 0 ? (
        <span className="text-critical">{deletionsLabel(deletions)}</span>
      ) : null}
    </span>
  );
}
