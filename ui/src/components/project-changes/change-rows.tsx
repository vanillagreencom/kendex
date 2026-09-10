import type { ChangedFile } from "@/bindings";
import type { FileEntry } from "@/components/files/file-tree-model";
import { cn } from "@/lib/utils";

/** The word at a changed file's right edge: what the action did to it, and
 *  whether the change is that it now exists or that it is gone.
 *
 *  One word per row, because the row is one file and the tree is read by
 *  scanning. `Earlier` is the one that carries weight: it says this file is
 *  not part of what just happened, which is exactly what a person cannot
 *  tell from a list of names. */
export const ADDED_WORD = "New";
export const REMOVED_WORD = "Gone";
export const EARLIER_WORD = "Earlier";
export const ALSO_EARLIER_WORD = "Also earlier";

function word(file: ChangedFile): string | null {
  switch (file.did) {
    case "older":
      return EARLIER_WORD;
    case "both":
      return ALSO_EARLIER_WORD;
    case "action":
      return file.added ? ADDED_WORD : file.removed ? REMOVED_WORD : null;
  }
}

/** One changed file as a row of the app's file tree, with that word drawn
 *  at its right edge. */
export function changeEntries(files: ChangedFile[]): FileEntry[] {
  return files.map((file) => {
    const said = word(file);
    return {
      path: file.path,
      meta: said ? (
        <span
          className={cn(
            "text-[11px] uppercase tracking-wide",
            file.did === "action" ? "text-muted-foreground" : "text-warning",
          )}
        >
          {said}
        </span>
      ) : undefined,
    };
  });
}

/** Rows for a set of paths nothing attributed to an action — the review a
 *  person opened themselves, where every pending change stands on its own
 *  and no word tells one from another. */
export const pathEntries = (paths: string[]): FileEntry[] =>
  paths.map((path) => ({ path }));

/** One offer's files as rows: worded where an action wrote and plain where
 *  none did.
 *
 *  An offer a person opened themselves has no action to attribute anything
 *  to, and the backend spells that as `older` on every file. Drawn through
 *  the words, every row of a review somebody asked for would read "Earlier"
 *  — telling them their own pending work belongs to some write they cannot
 *  see. `actionPaths` is empty exactly in that case, and it is the offer's
 *  own record of whether an action opened it. */
export const offerEntries = (offer: {
  files: ChangedFile[];
  actionPaths: string[];
}): FileEntry[] =>
  offer.actionPaths.length === 0
    ? pathEntries(offer.files.map((file) => file.path))
    : changeEntries(offer.files);
