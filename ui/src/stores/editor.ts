import { create } from "zustand";
import type { EditorInventory, Scope } from "@/bindings";
import type { Draft } from "@/lib/editor-draft";
import { sameScope, scopeKey } from "@/lib/scope";
import { type Held, pointAt } from "./editor-held";
import { onlyThese, type Unread } from "./editor-order";
import { fold, foldUnread, loadManifest, nextRead } from "./editor-read";
import { saveManifest } from "./editor-save";
import { named, readManifests, scopesNow } from "./editor-scopes";

interface EditorState {
  /** The single scope being edited — deliberately not the sidebar filter. */
  scope: Scope;
  draft: Draft | null;
  /** What the open place's file was when this draft was read from it. Sent
   *  back with a save, which the write refuses if the file has become
   *  something else since — the one check no caller has to remember to
   *  make. Null means there was no file, which is a base of its own. */
  base: string | null;
  /** Typing left at places the editor has since been pointed away from.
   *  Moving between places is what the per-place marks are for, so a move
   *  parks what is in hand rather than dropping it. */
  held: Held;
  inventory: EditorInventory | null;
  /** Every scope's saved manifest, keyed by scope. What the Library and the
   *  Customize index read to mark what has been customized; `draft` above is
   *  the one copy being edited. */
  saved: Record<string, Draft>;
  /** Whether {@link loadAll} has finished a pass. Until it has, a scope
   *  missing from `saved` was never asked for; after it has, that scope's
   *  manifest could not be read. */
  manifestsLoaded: boolean;
  /** Places whose last manifest read failed, each with what it said. The
   *  manifest they had is kept so a mark does not vanish, but it is
   *  last-known rather than current — the join reads these places as
   *  unknown instead of taking the old answer for a fresh one, and the
   *  note on screen says which places and why. */
  unreadPlaces: Unread;
  /** Why the last whole-manifest pass could not run at all — it never found
   *  out which places there are, so this belongs to no place and no
   *  per-place read can clear it. The next pass that runs does. */
  passError: string | null;
  /** True while a {@link loadAll} pass is running, so a retry cannot be
   *  pressed on top of the read it is waiting for. */
  manifestsReading: boolean;
  /** The place whose copy in hand was read before something else rewrote
   *  that place's manifest — a fork, or a discard. Saving it would write
   *  the older file back over what was recorded, so the save refuses while
   *  this names the place being edited. Null once it has been re-read. */
  outdated: string | null;
  dirty: boolean;
  loading: boolean;
  saving: boolean;
  error: string | null;
  /** Point the editor at a place, parking what is in hand at its own place
   *  and bringing back whatever was parked at this one. */
  setScope: (scope: Scope) => Promise<void>;
  /** The same move, skipped when the place asked for is already open with
   *  a copy in hand — so arriving at a package does not re-read over it. */
  openScope: (scope: Scope) => Promise<void>;
  /** Read one place's manifest — the open one, or the one named. Typing in
   *  hand is never replaced: `discardEdits` is how a caller says it means
   *  to, and {@link discard} is that caller. */
  load: (scope?: Scope, opts?: { discardEdits?: boolean }) => Promise<void>;
  /** Throw away the copy in hand and read the file again. */
  discard: () => Promise<void>;
  /** Read every scope's manifest, for the marks drawn outside the editor. */
  loadAll: () => Promise<void>;
  edit: (change: (draft: Draft) => Draft) => void;
  /** Say that this place's manifest was rewritten under the copy in hand. */
  outdate: (scope: Scope) => void;
  /** Take that back: the file turned out to be the one the copy came from
   *  after all. Only for the place it was said about. */
  current: (scope: Scope) => void;
  /** Say that this place's manifest would not read, and why. What is still
   *  in hand for it answers for an earlier moment until one does. */
  unread: (scope: Scope, why: string) => void;
  save: () => Promise<void>;
}

export const useEditorStore = create<EditorState>((set, get) => {
  // How many manifest passes are still running, so the reading flag comes
  // down when the last one lands rather than the first, and which of them
  // owns what the status says.
  let passes = 0;
  let latestPass = 0;

  return {
    scope: { scope: "global" },
    draft: null,
    base: null,
    held: {},
    inventory: null,
    saved: {},
    manifestsLoaded: false,
    unreadPlaces: {},
    passError: null,
    manifestsReading: false,
    outdated: null,
    dirty: false,
    loading: false,
    saving: false,
    error: null,

    setScope: async (scope) => {
      // The draft comes with the move; the choices do not. Held across the
      // switch they belong to where the editor was, so the form would offer
      // one project's skills, harnesses and hooks while its draft and its
      // save are about another — for as long as the read takes, and for
      // good if that read fails. Empty until this place answers for itself.
      set({ ...pointAt(get(), scope), inventory: null, error: null });
      await loadManifest();
    },

    outdate: (scope) => set({ outdated: scopeKey(scope) }),

    current: (scope) =>
      set((state) => ({
        outdated: state.outdated === scopeKey(scope) ? null : state.outdated,
      })),

    unread: (scope, why) =>
      set((state) => ({
        unreadPlaces: foldUnread(
          state.unreadPlaces,
          [[scopeKey(scope), `${named(scope)}: ${why}`]],
          nextRead(),
        ),
      })),

    openScope: async (scope) => {
      const state = get();
      if (state.draft && sameScope(state.scope, scope)) return;
      await state.setScope(scope);
    },

    load: loadManifest,

    discard: () => loadManifest(get().scope, { discardEdits: true }),

    loadAll: async () => {
      const token = nextRead();
      // Passes overlap — startup waits on settings first, the focus handler
      // fires on every return, and a fork adds one — so the status belongs
      // to the newest, not to whichever lands last. The saved fold is safe
      // either way: it is per place and already ticketed.
      const newest = () => token === latestPass;
      latestPass = token;
      passes += 1;
      set({ manifestsReading: true });
      const done = () => {
        passes -= 1;
        if (passes === 0) set({ manifestsReading: false });
      };
      try {
        const { read, unread } = await readManifests();
        // Every place there is *now*, asked at the moment this pass writes
        // rather than when it started. A pass carries the list it began
        // with, so a project unregistered while it ran is still among its
        // results — and folding those in puts back what the unregistering,
        // or a later pass, already took away. Nothing would take it away
        // again: no later pass reads a scope that is not there any more.
        const places = new Set(scopesNow().map(scopeKey));
        set((state) => ({
          // A place whose manifest would not load keeps the last one that
          // did, rather than being dropped from `saved` and taking a mark
          // that was right with it.
          saved: onlyThese(fold(state.saved, read, token), places),
          // And how each place's read went folds the same way, under the
          // same token: this pass answers for the places it reached, and
          // for none of the others. Replacing the whole list instead let a
          // pass that failed put back a mark a newer read of one place had
          // already cleared.
          unreadPlaces: onlyThese(
            foldUnread(
              state.unreadPlaces,
              [
                ...read.map(([key]) => [key, null] as [string, string | null]),
                ...unread.map(
                  ([key, why]) => [key, why] as [string, string | null],
                ),
              ],
              token,
            ),
            places,
          ),
          // The pass ran, so whatever stopped the last one from running is
          // over; what each place said travels with that place.
          ...(newest() ? { manifestsLoaded: true, passError: null } : {}),
        }));
        // The pass answers for every place, the open one included. A draft
        // with nothing typed in it is the file's, not the person's: another
        // process can rewrite that place while the window is away, and
        // holding a clean copy leaves the form showing values that are
        // already gone. One with typing in it stays, and its save is still
        // refused on its base. This read rather than the fold above,
        // because only a read pairs a draft with the base it came from.
        //
        // Unless the place the editor is pointed at is not one of them any
        // more. Reading a project that has just been unregistered puts back
        // the very state the prune above took away, and no later pass asks
        // for it again — so the note would name an untracked project for
        // good, and its retry would prune and re-add it every press.
        if (!get().dirty && places.has(scopeKey(get().scope)))
          await get().load();
      } catch (thrown) {
        // A rejected read is a read that failed, not one still running: a
        // pass that says nothing leaves every place reading as in-flight
        // forever, with no note and no retry.
        //
        // This pass got to no place at all — it could not even find out
        // which places there are — so every manifest still in hand is one
        // nothing re-checked. They stay, so a mark does not vanish, and
        // every one of them is unread: none of them may answer as current.
        if (newest())
          set((state) => ({
            manifestsLoaded: false,
            passError: String(thrown),
            unreadPlaces: foldUnread(
              state.unreadPlaces,
              Object.keys(state.saved).map((key) => [key, String(thrown)]),
              token,
            ),
          }));
      } finally {
        done();
      }
    },

    edit: (change) => {
      const { draft } = get();
      if (!draft) return;
      set({ draft: change(draft), dirty: true });
    },

    save: saveManifest,
  };
});
