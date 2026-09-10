// The words the Bookmarks surfaces use. Product prose, kept here so it can
// be read as writing rather than found across components.
//
// A bookmark is a marketplace package or curated set you saved to find
// again. Every sentence below says what a control does or what a state is.
import type { BookmarkItem } from "@/bindings";
import { kindLabel } from "@/lib/labels";

/** The tab, and the word for one of these wherever it is named. */
export const BOOKMARKS_TAB = "Bookmarks";

/** Under the list, once, because a person meeting the tab has not met the
 *  idea. */
export const BOOKMARKS_EXPLAINER =
  "A bookmark is a marketplace package or curated set you saved to find again. Saving one installs nothing and changes no project.";

export const BOOKMARKS_EMPTY =
  "Nothing saved yet. Save a package or a curated set from a marketplace to find it here.";
export const BOOKMARKS_UNREADABLE = "Saved items could not be read.";
export const BOOKMARKS_LAST_KNOWN =
  "Saved items could not be read. These are the last kendex could check.";
export const BOOKMARKS_SEARCH = "Search saved items";
export const BOOKMARKS_NONE_MATCH = "No saved item matches this search.";

/** What a saved item is, in the words the rest of the app uses. */
export const savedKindLabel = (item: BookmarkItem): string =>
  item.is === "bundle" ? "Curated set" : kindLabel(item.kind);

/** The row's second line: what it is, and which marketplace it came from. */
export const savedSummary = (item: BookmarkItem, marketplace: string): string =>
  `${savedKindLabel(item)} · ${marketplace}`;

/** The control, in both directions. The accessible names carry the item,
 *  so a reader landing on the control is told what pressing it saves
 *  rather than only that it is a bookmark. */
export const REMOVE_BOOKMARK_ACTION = "Remove bookmark";
export const bookmarkLabel = (name: string): string => `Bookmark ${name}`;
export const removeBookmarkLabel = (name: string): string =>
  `Remove bookmark from ${name}`;

export const savedToast = (name: string): string => `Saved ${name}.`;
export const forgotToast = (name: string): string =>
  `Removed the bookmark for ${name}. Anything installed from it stays installed.`;

/** Said on a saved row whose marketplace nothing here subscribes to. It is
 *  not a failure: the row opens, and opening it is what reads the
 *  marketplace. */
export const NOT_SUBSCRIBED_NOTE =
  "Nothing here subscribes to this marketplace, so what it offers has not been read. Open it to read it; installing subscribes first.";

/** The one word each standing shows beside a row, so the list can be
 *  scanned without reading every reason. */
export const NOT_OFFERED_WORD = "No longer offered";
export const UNAVAILABLE_WORD = "Unavailable";
export const NOT_SUBSCRIBED_WORD = "Not subscribed";
