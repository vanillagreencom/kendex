import type { FileStatus, PackageDiff } from "@/bindings";

/** `+12` / `−3`, for totals and per-file counts. The minus is a real minus
 *  sign — a hyphen reads as a bullet at small sizes. */
export const additionsLabel = (count: number): string => `+${count}`;
export const deletionsLabel = (count: number): string => `−${count}`;

/** Statuses worth a word next to the path — "modified" is the default
 *  reading of a row in a diff and saying it would just be noise. */
export const DIFF_STATUS_LABELS: Record<FileStatus, string | null> = {
  added: "Added",
  removed: "Removed",
  modified: null,
  binary: "Binary file",
  "too-large": "Too large to show",
};

/** Gutter width in ch for line numbers, sized to the widest number the
 *  diff actually holds so short diffs don't carry a wide gutter. */
export function lineNumberWidth(diff: PackageDiff): number {
  let widest = 2;
  for (const file of diff.files) {
    for (const hunk of file.hunks) {
      for (const line of hunk.lines) {
        const n = Math.max(line.oldNo ?? 0, line.newNo ?? 0);
        widest = Math.max(widest, String(n).length);
      }
    }
  }
  return widest;
}
