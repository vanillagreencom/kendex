import { useEffect, useRef, useState } from "react";
import type { FileChanges, FileMode, PackageDiff, Refused } from "@/bindings";
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
  modeChangeNote,
  SAME_CONTENT_NOTE,
  WORKING_TREE_SIDE,
} from "@/lib/copy-commit-offer";
import {
  CHANGED_FILES_TREE_LABEL,
  UNCHANGED_FILE_NOTE,
} from "@/lib/copy-files";
import { readOrder } from "@/lib/read-state";

/** What one read of a file the offer covers came back with: still out, the
 *  diff, the words of a read that would not run, or the file having
 *  stopped being changed. */
type Read =
  | { at: "reading" }
  | { at: "shown"; diff: PackageDiff; mode: FileMode | null }
  | { at: "nothing" }
  | { at: "refused"; said: string[] };

/** The changed files kendex owns in one project, as the app's file tree,
 *  with each one opening what changed in it.
 *
 *  A list of paths asks a person to answer for a change they cannot see.
 *  The tree names the files the way every other file list in the app does,
 *  and the diff arrives in the same panel a package comparison arrives in,
 *  over whatever asked for it rather than in place of it: the commit dialog
 *  is still asking its question underneath, and the review is still the
 *  page the reader is on.
 *
 *  Only what the offer covers reaches this. The read behind each row asks
 *  core for one path and core answers `Nothing` for any path its own fresh
 *  scan does not cover, so a shared configuration file — which kendex
 *  writes one key in and never commits whole — has no route to a diff here,
 *  and neither has anything else in the repository. */
export function ChangedFiles({
  root,
  entries,
  onOpen,
}: {
  root: string;
  /** The rows this tree lists, with whatever the surface says about each —
   *  what the action did to it, whether it is new or gone. */
  entries: FileEntry[];
  /** Which path is open, for a surface with an action about one file. Which
   *  path that is lives here rather than in the caller: the panel and the
   *  read behind it are this component's, and two owners of one selection
   *  would let a caller open a panel with nothing under it. */
  onOpen?: (path: string | null) => void;
}) {
  const [open, setOpen] = useState<string | null>(null);
  const [read, setRead] = useState<Read>({ at: "reading" });
  // One ticket per read, and only the newest may write. The path cannot
  // stand in for the ticket: a person moving A → B → A, or closing A and
  // opening it again, has two reads out about the same file, and the older
  // one landing last would put a scan the project has moved past under the
  // newer one's name.
  const order = useRef(readOrder());

  // The rows can be read again out from under an open panel: putting a
  // file back takes it to what the last commit holds, and the next read
  // carries no row for it. Nothing stands under the panel then, so it
  // closes — and the caller's own record of what is open closes with it,
  // because one selection has one owner. The button that acts on the open
  // file goes back to acting on all of them, rather than on a path this
  // project no longer holds a change for.
  useEffect(() => {
    if (open === null || entries.some((entry) => entry.path === open)) return;
    setOpen(null);
    onOpen?.(null);
  }, [entries, open, onOpen]);

  const show = (path: string) => {
    const ticket = order.current.begin();
    setOpen(path);
    onOpen?.(path);
    setRead({ at: "reading" });
    void commands.commitOfferFileChanges(root, path).then((response) => {
      if (!order.current.lands(ticket)) return;
      setRead(answerOf(response));
    });
  };

  // Closing takes a ticket of its own, so a read still out when the panel
  // shuts can no longer write: it is not the newest any more.
  const close = () => {
    order.current.begin();
    setOpen(null);
    onOpen?.(null);
  };

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
          <Shown read={read} />
        )}
      </ChangesPanel>
    </>
  );
}

/** What the commit carries for the file that is open: the comparison, and
 *  the mode change beside it where the commit carries one too. A file
 *  whose text does not move says so above that line rather than leaving
 *  the empty comparison to speak for it, and one that changed back since
 *  the offer was read has neither and says that instead. */
function Shown({ read }: { read: Extract<Read, { at: "reading" | "shown" }> }) {
  if (read.at === "reading") return <ChangesViewer diff={null} />;
  const moved = read.diff.files.length > 0;
  if (!moved && read.mode === null)
    return (
      <p className="text-sm text-muted-foreground">{UNCHANGED_FILE_NOTE}</p>
    );
  return (
    <div className="space-y-3">
      {read.mode !== null ? (
        <div className="space-y-1 text-sm text-muted-foreground">
          {moved ? null : <p>{SAME_CONTENT_NOTE}</p>}
          <p>{modeChangeNote(read.mode.before, read.mode.after)}</p>
        </div>
      ) : null}
      {moved ? <ChangesViewer diff={read.diff} /> : null}
    </div>
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
      return {
        at: "shown",
        diff: response.data.diff,
        mode: response.data.mode,
      };
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
