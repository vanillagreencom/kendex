import { TriangleAlert } from "lucide-react";
import type { FileDiff } from "@/bindings";
import { DIFF_LOSSY_NOTE } from "@/lib/copy-files";
import { additionsLabel, DIFF_STATUS_LABELS, deletionsLabel } from "@/lib/diff";
import { cn } from "@/lib/utils";

/** The app's one diff view: what changed in one file, under a bar naming
 *  it and counting the change. Lines ride the semantic good/critical
 *  tokens — never raw green/red — so both themes read the way the rest of
 *  the app does.
 *
 *  It sits where the file preview sits, on the right of the tree, so
 *  reading a package's files and reading what changed in them are the same
 *  movement.
 *
 *  A file whose bytes are not all text is decoded lossily to be compared at
 *  all, and the pane says so: the lines below hold a replacement character
 *  where the file holds bytes nobody can read as text, and this window is
 *  the one a person approves a commit from. Text they were never shown must
 *  not pass for the file. */
export function DiffPane({
  file,
  gutterCh,
  note,
}: {
  /** Null before a file has been picked. */
  file: FileDiff | null;
  /** Line-number column width in ch, so every file of one comparison
   *  shares a gutter and the text starts at the same place in each. */
  gutterCh: number;
  /** What to say in place of a diff, where no file has been picked. */
  note: string;
}) {
  if (!file) {
    return <p className="text-sm text-muted-foreground">{note}</p>;
  }
  const status = DIFF_STATUS_LABELS[file.status];
  return (
    <div className="overflow-hidden rounded-lg border">
      <div className="sticky top-0 z-10 flex items-center gap-2 border-b bg-muted/60 px-3 py-1.5 backdrop-blur-sm">
        <span className="min-w-0 truncate font-mono text-xs text-muted-foreground">
          {file.path}
        </span>
        {status ? (
          <span className="shrink-0 text-xs text-muted-foreground">
            {status}
          </span>
        ) : null}
        <span className="ml-auto flex shrink-0 gap-2 font-mono text-xs tabular-nums">
          {file.additions > 0 ? (
            <span className="text-good">{additionsLabel(file.additions)}</span>
          ) : null}
          {file.deletions > 0 ? (
            <span className="text-critical">
              {deletionsLabel(file.deletions)}
            </span>
          ) : null}
        </span>
      </div>
      {file.lossy ? (
        <p className="flex items-center gap-2 border-b border-warning/30 bg-warning/5 px-3 py-1.5 text-warning text-xs">
          <TriangleAlert className="size-3.5 shrink-0" />
          {DIFF_LOSSY_NOTE}
        </p>
      ) : null}
      <div className="overflow-x-auto">
        {file.hunks.map((hunk) => (
          <div key={hunk.header}>
            <div className="bg-muted/40 px-3 py-1 font-mono text-[11px] text-muted-foreground">
              {hunk.header}
            </div>
            {hunk.lines.map((line) => (
              <div
                // Within a hunk every line carries at least one line
                // number, and no two lines share the same pair.
                key={`${line.oldNo ?? "a"}:${line.newNo ?? "r"}`}
                className={cn(
                  "flex font-mono text-xs leading-5",
                  line.kind === "add" && "bg-good/10",
                  line.kind === "remove" && "bg-critical/10",
                )}
              >
                <span
                  className="shrink-0 select-none pr-2 text-right text-muted-foreground/60"
                  style={{ width: `${gutterCh + 1.5}ch` }}
                >
                  {line.oldNo ?? ""}
                </span>
                <span
                  className="shrink-0 select-none pr-2 text-right text-muted-foreground/60"
                  style={{ width: `${gutterCh + 1.5}ch` }}
                >
                  {line.newNo ?? ""}
                </span>
                <span
                  className={cn(
                    "w-4 shrink-0 select-none text-center",
                    line.kind === "add" && "text-good",
                    line.kind === "remove" && "text-critical",
                  )}
                >
                  {line.kind === "add"
                    ? "+"
                    : line.kind === "remove"
                      ? "−"
                      : ""}
                </span>
                <span className="whitespace-pre pr-3">{line.text}</span>
              </div>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}
