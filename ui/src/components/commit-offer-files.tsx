import { useRef, useState } from "react";
import type { FileChanges, PackageDiff, Refused } from "@/bindings";
import { commands } from "@/bindings";
import { ChangesPanel } from "@/components/files/changes-panel";
import { ChangesViewer } from "@/components/files/changes-viewer";
import { FileTree } from "@/components/files/file-tree";
import type { FileEntry } from "@/components/files/file-tree-model";
import { StatusNote } from "@/components/status-note";
import {
  CHANGES_READ_FAILED_TITLE,
  didNotFinish,
  LAST_COMMIT_SIDE,
  WORKING_TREE_SIDE,
} from "@/lib/copy-commit-offer";
import {
  CHANGED_FILES_TREE_LABEL,
  UNCHANGED_FILE_NOTE,
} from "@/lib/copy-files";

/** What one read of a file the offer covers came back with: still out, the
 *  diff, the words of a read that would not run, or the file having
 *  stopped being changed. */
type Read =
  | { at: "reading" }
  | { at: "shown"; diff: PackageDiff }
  | { at: "nothing" }
  | { at: "refused"; said: string[] };

/** The files a commit would carry, as the app's file tree, with each one
 *  opening what changed in it.
 *
 *  A list of paths asks a person to answer for a change they cannot see.
 *  The tree names the files the way every other file list in the app does,
 *  and the diff arrives in the same panel a package comparison arrives in,
 *  over the dialog rather than in place of it: the question the dialog
 *  asks is still the question. */
export function CommitOfferFiles({
  root,
  paths,
}: {
  root: string;
  /** The paths this section lists, as the offer named them. */
  paths: string[];
}) {
  const [open, setOpen] = useState<string | null>(null);
  const [read, setRead] = useState<Read>({ at: "reading" });
  // The file the newest read was asked about. A person clicking down a
  // list has several reads out at once, and only the one they are still
  // looking at may write — an older answer landing last would put one
  // file's diff under another file's name.
  const asked = useRef<string | null>(null);

  const show = (path: string) => {
    asked.current = path;
    setOpen(path);
    setRead({ at: "reading" });
    void commands.commitOfferFileChanges(root, path).then((response) => {
      if (asked.current !== path) return;
      setRead(answerOf(response));
    });
  };

  const close = () => {
    asked.current = null;
    setOpen(null);
  };

  const entries: FileEntry[] = paths.map((path) => ({ path }));
  return (
    <>
      <FileTree
        entries={entries}
        selected={open}
        onSelect={show}
        label={CHANGED_FILES_TREE_LABEL}
      />
      <ChangesPanel
        open={open !== null}
        onClose={close}
        fromLabel={LAST_COMMIT_SIDE}
        toLabel={WORKING_TREE_SIDE}
      >
        {read.at === "refused" ? (
          <StatusNote tone="critical" title={CHANGES_READ_FAILED_TITLE}>
            <pre className="overflow-auto whitespace-pre-wrap break-all font-mono text-xs">
              {read.said.join("\n")}
            </pre>
          </StatusNote>
        ) : read.at === "nothing" ? (
          <p className="text-sm text-muted-foreground">{UNCHANGED_FILE_NOTE}</p>
        ) : (
          <ChangesViewer diff={read.at === "shown" ? read.diff : null} />
        )}
      </ChangesPanel>
    </>
  );
}

/** One command answer as the panel's state. A transport failure is a read
 *  that would not run, said the way a git refusal is: the panel is about
 *  this one file, and neither leaves it able to show a diff. */
function answerOf(
  response:
    | { status: "ok"; data: FileChanges }
    | { status: "error"; error: string },
): Read {
  if (response.status === "error") {
    return { at: "refused", said: [response.error] };
  }
  switch (response.data.kind) {
    case "shown":
      return { at: "shown", diff: response.data.diff };
    case "nothing":
      return { at: "nothing" };
    case "refused":
      return { at: "refused", said: saidOf(response.data.refused) };
  }
}

/** A refusal's own words, or what a read that ran out of time can say
 *  instead — it has none. */
const saidOf = (refused: Refused): string[] =>
  refused.timedOut ? [didNotFinish(refused.seconds)] : refused.said;
