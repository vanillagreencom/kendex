// Every sentence the shared file tree, preview and diff viewer show. One
// place, because the same words appear on the package page, the
// marketplace page and the commit dialog, and three spellings of "this
// file couldn't be shown" would read as three different failures.

export const FILES_TAB = "Files";
export const FILE_TREE_LABEL = "Files in this package";
export const CHANGED_FILES_TREE_LABEL = "Changed files";
export const FILE_TRUNCATED_NOTE = "Showing first 64 KB";
export const FILE_READ_FAILED_TITLE = "This file couldn't be shown";
export const FILES_READING_NOTE = "Reading this package's files…";
export const NO_FILES_NOTE = "This package ships no files.";
export const NO_README_NOTE = "This package carries no README.";
export const PICK_A_FILE_NOTE = "Pick a file to read it.";
export const PICK_A_CHANGE_NOTE = "Pick a file to see what changed in it.";
export const NO_CHANGES_NOTE = "These versions have identical files.";
export const UNCHANGED_FILE_NOTE =
  "This file has changed back since kendex looked; there is nothing left to show.";
export const COMPARING_NOTE = "Comparing…";
export const CHANGES_TITLE = "Changes";
export const CLOSE_CHANGES_LABEL = "Close";

/** Bytes as a person reads them at a glance, beside a file in the tree. */
export function fileSizeLabel(size: number): string {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${Math.round(size / 1024)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

/** What two sides of a comparison are, said once in the panel's own bar:
 *  `v1.2.0 → installed`. */
export const comparing = (from: string, to: string): string =>
  `${from} → ${to}`;
