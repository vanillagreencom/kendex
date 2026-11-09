import { useEffect } from "react";
import type { SourceReadRefused } from "@/bindings";
import { FilePane } from "@/components/files/file-pane";
import { StatusNote } from "@/components/status-note";
import { Skeleton } from "@/components/ui/skeleton";
import { FILE_READ_FAILED_TITLE, NO_FILES_NOTE } from "@/lib/copy-files";
import {
  packageFileRefusalLine,
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
  | { status: "error"; error: SourceReadRefused | string }
  | { status: "ok"; path: string; content: string; truncated: boolean };

const LOADING: PreviewState = { status: "loading" };

/** A page read that did not land, as the refusal it came back with. */
const refusalOf = ({ read, unfetched }: SourceRead) =>
  unfetched === null
    ? read.status === "failed"
      ? read.error
      : null
    : ({ kind: "source-pending", source: unfetched } as const);

/** What the pane draws without reading anything itself, or the file it
 *  has to read: the picked path; else the README the page already read;
 *  else, with no README, the package's first file, so the pane is never
 *  empty on open. */
const shownOf = (
  held: PackageAnswer | undefined,
  path: string | null,
): PreviewState | { file: string } => {
  if (path !== null) return { file: path };
  if (!held) return LOADING;
  const readme = refusalOf(held.reads.readme);
  if (readme !== null) return { status: "error", error: readme };
  if (held.reads.readme.read.status === "pending") return LOADING;
  if (held.readme) return { status: "ok", ...held.readme };
  const files = refusalOf(held.reads.files);
  if (files !== null) return { status: "error", error: files };
  if (held.reads.files.read.status === "pending") return LOADING;
  const first = held.files[0];
  return first
    ? { file: first.path }
    : { status: "error", error: NO_FILES_NOTE };
};

/** One file of an installed package, drawn in the app's one file pane.
 *  `path` null means the readme, which is what a package opens on. Its
 *  reads are the page's, kept with the package's: the README and the file
 *  list come from the page's own answers, and a file read here is kept
 *  beside them until the package is read again. */
export function FilePreview({
  reference,
  path,
}: {
  reference: PackageRef;
  path: string | null;
}) {
  const held = usePackageReads((s) => s.answers[packageReadKey(reference)]);
  const shown = shownOf(held, path);
  const file = "file" in shown ? shown.file : null;
  const ticket = held?.ticket;
  // biome-ignore lint/correctness/useExhaustiveDependencies: a new read of the package empties what this file was read under
  useEffect(() => {
    if (file !== null) ensureFile(reference, file);
  }, [reference, file, ticket]);

  const answer = file === null ? null : held?.opened[file]?.answer;
  const state: PreviewState =
    "file" in shown
      ? answer
        ? answer.status === "ok"
          ? { status: "ok", ...answer.data }
          : { status: "error", error: answer.error }
        : LOADING
      : shown;

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

  // One slot, drawn as a failure: what can fail here is the one file. Why
  // the not-downloaded kind never reaches it, and is still read through
  // the judge, is `packageFileRefusalLine`'s.
  if (state.status === "error") {
    return (
      <StatusNote tone="critical" title={FILE_READ_FAILED_TITLE}>
        {packageFileRefusalLine(state.error)}
      </StatusNote>
    );
  }

  return <FilePane {...state} />;
}
