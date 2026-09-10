import type { PackageFile } from "@/bindings";
import type { FileEntry } from "@/components/files/file-tree-model";
import { README_TAG } from "@/lib/copy";
import { fileSizeLabel } from "@/lib/copy-files";

/** What a package's files say about themselves in the tree: each file's
 *  size, and on the README the marker naming the file the preview opens on.
 *
 *  One mapper for every surface that lists a package's files — the
 *  installed package's Files tab and the same package read from a
 *  marketplace — because they list the same files, and a marker drawn on
 *  one side alone reads as two different packages. */
export const packageFileEntries = (files: PackageFile[]): FileEntry[] =>
  files.map((file) => ({
    path: file.path,
    meta: file.isReadme ? (
      <>
        {README_TAG} {fileSizeLabel(file.size)}
      </>
    ) : (
      fileSizeLabel(file.size)
    ),
  }));
