// Saved marketplace items, as state.
//
// A bookmark is the person's, not a place's: the same list heads the
// Bookmarks tab and decides whether the Bookmark control on a marketplace
// row, a package page, a set card or a set page is already saved. It is
// read once here and every surface reads it from here, so no two of them
// can disagree about what is saved.
//
// Nothing in this file decides what a bookmark records or whether two
// spellings of a marketplace are one — those are core's answers, reached
// through the commands.
import { useMemo } from "react";
import { create } from "zustand";
import { type Bookmark, commands, type SavedItem } from "@/bindings";
import { settled } from "@/lib/settled";

export type { SavedItem };

/** How a read stands: never started, out, answered, or failed with the
 *  reason. Kept apart from the rows so a failure over rows that landed
 *  earlier can head them as last-known rather than throwing them away. */
export type Read =
  | { status: "idle" }
  | { status: "reading" }
  | { status: "read" }
  | { status: "failed"; error: string };

interface BookmarksState {
  /** The rows the last read that answered landed. Not read on its own by
   *  any surface: what may be claimed from it depends on the two fields
   *  below, so the three are read together through [`useBookmarksAnswer`]. */
  saved: SavedItem[];
  /** Whether any answer has ever landed, which is what tells a failure
   *  with rows behind it from one with nothing. */
  everRead: boolean;
  read: Read;
  /** A write in flight, so a surface can hold its own buttons. */
  busy: boolean;
  /** What a write refused with, or null. Cleared when the next one starts. */
  refused: string | null;
  load: () => Promise<void>;
  /** Read the list if nothing has read it yet. What a Bookmark control
   *  calls: a table draws one per row, and a read per row would be one
   *  resolution of every saved item per package on screen. A write reads
   *  again on its own, and the Bookmarks tab asks for a fresh read when it
   *  opens, so nothing here goes stale for want of a second ask. */
  ensure: () => void;
  add: (bookmark: Bookmark) => Promise<boolean>;
  remove: (bookmark: Bookmark) => Promise<boolean>;
  clearRefusal: () => void;
}

export const useBookmarksStore = create<BookmarksState>((set, get) => {
  // Every surface drawing a Bookmark control starts a read, and every save
  // starts another behind it; the replies arrive in any order. A ticket
  // taken as each read leaves orders them again on arrival: a reply from
  // any read but the newest one issued is a view of a list something newer
  // has already replaced, and holding it would put a removed bookmark back
  // on the list.
  let issued = 0;
  const ticket = () => ++issued;

  /** Take one read's answer, held only while its ticket is the newest one
   *  ISSUED — measured against what has been asked for rather than against
   *  what has come back, so a read that crossed a save is superseded the
   *  moment that save starts its own read, whichever reply lands first. */
  const hold = (answer: Partial<BookmarksState>, at: number) => {
    if (at !== issued) return;
    set(answer);
  };

  return {
    saved: [],
    everRead: false,
    read: { status: "idle" },
    busy: false,
    refused: null,

    load: async () => {
      const at = ticket();
      set({ read: { status: "reading" } });
      const answer = await settled(commands.bookmarksList());
      if (answer.status === "error") {
        // The rows that landed before stay, headed as the last answer that
        // came back rather than thrown away over one read that did not.
        hold({ read: { status: "failed", error: answer.error } }, at);
        return;
      }
      hold(
        { saved: answer.data, everRead: true, read: { status: "read" } },
        at,
      );
    },

    ensure: () => {
      if (get().read.status !== "idle") return;
      void get().load();
    },

    add: (bookmark) => write(set, get, () => commands.bookmarkAdd(bookmark)),
    remove: (bookmark) =>
      write(set, get, () => commands.bookmarkRemove(bookmark)),

    clearRefusal: () => set({ refused: null }),
  };
});

/** One write against the index: the refusal is kept where a surface can
 *  say it, and the list is read again whatever happened — a refusal is no
 *  account of what is saved. */
async function write<T>(
  set: (partial: Partial<BookmarksState>) => void,
  get: () => BookmarksState,
  body: () => Promise<
    { status: "ok"; data: T } | { status: "error"; error: string }
  >,
): Promise<boolean> {
  set({ busy: true, refused: null });
  const answer = await settled(body());
  set({ busy: false });
  if (answer.status === "error") set({ refused: answer.error });
  await get().load();
  return answer.status === "ok";
}

/** What the bookmark index says, as one answer a surface reads whole.
 *
 *  The rows, whether any read has landed, and how the last read went are
 *  three facts, and a surface that read only the rows would present an
 *  index kendex could not read as a person with nothing saved. So the rows
 *  are not offered on their own: every state carries what it has, and no
 *  caller can claim "none" without having been handed `read` with an empty
 *  list. */
export type BookmarksAnswer =
  /** No read has landed. Nothing may be claimed about what is saved. */
  | { shown: "waiting" }
  /** The last read failed and nothing landed before it. */
  | { shown: "unreadable"; error: string }
  /** The last read failed over rows an earlier one landed. They stand,
   *  headed as the last answer that came back rather than as current. */
  | { shown: "lastKnown"; saved: SavedItem[]; error: string }
  /** A read answered. An empty list here is a person with nothing saved,
   *  which is the one state that claim may be made from. */
  | { shown: "read"; saved: SavedItem[] };

/** The one reading of the store's read state, as a function over the three
 *  fields so the hook and its test drive the same rule. */
export function bookmarksAnswer(
  saved: SavedItem[],
  read: Read,
  everRead: boolean,
): BookmarksAnswer {
  if (read.status === "failed")
    return everRead
      ? { shown: "lastKnown", saved, error: read.error }
      : { shown: "unreadable", error: read.error };
  return everRead ? { shown: "read", saved } : { shown: "waiting" };
}

/** What the bookmark index says, for a surface that draws it. Recomputed
 *  from the three fields the store holds; each is a stable reference, so
 *  nothing here mints one per render. */
export function useBookmarksAnswer(): BookmarksAnswer {
  const saved = useBookmarksStore((s) => s.saved);
  const read = useBookmarksStore((s) => s.read);
  const everRead = useBookmarksStore((s) => s.everRead);
  return useMemo(
    () => bookmarksAnswer(saved, read, everRead),
    [saved, read, everRead],
  );
}
