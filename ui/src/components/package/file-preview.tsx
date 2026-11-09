import { useEffect } from "react";
import type { ItemSource } from "@/bindings";
import { FilePane } from "@/components/files/file-pane";
import { StatusNote } from "@/components/status-note";
import { Skeleton } from "@/components/ui/skeleton";
import { FILE_READ_FAILED_TITLE } from "@/lib/copy-files";
import {
  packageFileRefusalLine,
  packageReadmeNote,
  type SourceRead,
} from "@/lib/package-read-state";
import type { PackageRef } from "@/stores/nav";
import {
  ensureFile,
  type PackageAnswer,
  packageReadKey,
  usePackageReads,
} from "@/stores/package-reads";

type PreviewState =
  | { status: "loading" }
  | { status: "error"; line: string }
  | { status: "ok"; path: string; content: string; truncated: boolean };

const LOADING: PreviewState = { status: "loading" };

/** What the pane draws, and the file it reads to draw it, null when it
 *  draws the page's own README. Opens on the picked path; else on the
 *  README; else, for a package with none, on its first file, so the pane is
 *  never empty on open. */
const previewOf = (
  picked: string | null,
  readme: ItemSource | null,
  readmeRead: SourceRead,
  first: string,
  opened: PackageAnswer["opened"] | undefined,
): { file: string | null; state: PreviewState } => {
  let file = picked;
  if (file === null) {
    const note = packageReadmeNote(readmeRead);
    if (note) return { file, state: { status: "error", line: note.line } };
    if (readmeRead.read.status === "pending") return { file, state: LOADING };
    if (readme) return { file, state: { status: "ok", ...readme } };
    file = first;
  }
  const answer = opened?.[file]?.answer;
  if (!answer) return { file, state: LOADING };
  return {
    file,
    state:
      answer.status === "ok"
        ? { status: "ok", ...answer.data }
        : { status: "error", line: packageFileRefusalLine(answer.error) },
  };
};

/** One file of an installed package, drawn in the app's one file pane.
 *  `path` null means the README, which is what a package opens on. Mounted
 *  under a file list that landed with files in it, so `first` is always a
 *  file. A file read here is kept beside the package's own reads until the
 *  package is read again. */
export function FilePreview({
  reference,
  path,
  readme,
  readmeRead,
  first,
}: {
  reference: PackageRef;
  path: string | null;
  /** The README the page read, and how that read went. */
  readme: ItemSource | null;
  readmeRead: SourceRead;
  first: string;
}) {
  const held = usePackageReads((s) => s.answers[packageReadKey(reference)]);
  const { file, state } = previewOf(
    path,
    readme,
    readmeRead,
    first,
    held?.opened,
  );
  const ticket = held?.ticket;
  // biome-ignore lint/correctness/useExhaustiveDependencies: a new read of the package empties what this file was read under
  useEffect(() => {
    if (file !== null) ensureFile(reference, file);
  }, [reference, file, ticket]);

  if (state.status === "loading") {
    return (
      <div className="space-y-2">
        <Skeleton className="h-3.5 w-3/4" />
        <Skeleton className="h-3.5 w-full" />
        <Skeleton className="h-3.5 w-5/6" />
        <Skeleton className="h-3.5 w-2/3" />
      </div>
    );
  }

  // One slot, drawn as a failure: the README the page read or the one file
  // this pane read, each worded by `package-read-state.ts`. Why the
  // not-downloaded kind never reaches it is `packageFileRefusalLine`'s.
  if (state.status === "error") {
    return (
      <StatusNote tone="critical" title={FILE_READ_FAILED_TITLE}>
        {state.line}
      </StatusNote>
    );
  }

  return <FilePane {...state} />;
}
