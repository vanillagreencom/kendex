import type { ReactNode } from "react";
import { FileTree } from "@/components/files/file-tree";
import type { FileEntry } from "@/components/files/file-tree-model";
import { cn } from "@/lib/utils";

/** The split: the tree on the left, one file on the right. Every surface
 *  in the app that shows more than one file draws this — a package's own
 *  files with the file's content beside them, a set of changes with that
 *  file's diff.
 *
 *  The tree column is fixed and the pane takes the rest, so moving between
 *  files never moves the tree under the pointer. On a narrow window the
 *  two stack, tree first: a list of files a reader can still get at beats a
 *  pane squeezed beside a column too thin to read. */
export function FileBrowser({
  entries,
  selected,
  onSelect,
  label,
  className,
  children,
}: {
  entries: FileEntry[];
  selected: string | null;
  onSelect: (path: string) => void;
  /** What the tree is a tree of, for screen readers. */
  label: string;
  className?: string;
  /** The right side: the chosen file's content, or its diff. */
  children: ReactNode;
}) {
  return (
    <div className={cn("flex flex-col gap-6 lg:flex-row lg:gap-8", className)}>
      <div className="w-full shrink-0 lg:w-[19rem]">
        <FileTree
          entries={entries}
          selected={selected}
          onSelect={onSelect}
          label={label}
        />
      </div>
      <div className="min-w-0 flex-1">{children}</div>
    </div>
  );
}
