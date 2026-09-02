import { create } from "zustand";
import {
  commands,
  type EditorInventory,
  type Scope,
  type ScopeSettings,
  type SettingsEdit,
} from "@/bindings";
import { type Draft, emptyDraft } from "@/lib/editor-draft";

import { everyPlace, sameScope } from "@/lib/scope";
import { settingsDraft, withEdit } from "@/lib/settings-rows";
import { saying } from "@/lib/undone";
import { useAuditStore } from "./audit";
import {
  mergedPlaces,
  opening,
  placesOf,
  readDraft,
  readError,
  readPlace,
  recordedRead,
} from "./editor-cache";
import { useScanStore } from "./scan";
import { useSettingsStore } from "./settings";

export { openInventory } from "./editor-cache";

interface EditorState {
  /** The single scope being edited — deliberately not the sidebar filter. */
  scope: Scope;
  draft: Draft | null;
  /** What the manifest file was when `draft` was read from it — sent back
   *  with every save, so a copy of a file something else has since written
   *  is refused instead of putting the older file back. */
  base: string | null;
  /** Every scope's saved manifest, keyed by scope. What the Library and the
   *  Customize index read to mark what has been customized; `draft` above is
   *  the one copy being edited. */
  saved: Record<string, Draft>;
  /** Every scope's editor inventory, keyed by scope. Keyed rather than
   *  held loose beside `scope`, so a read belonging to one place cannot be
   *  served as another's answer: read it through {@link openInventory},
   *  which finds nothing for a place that was never read or whose read
   *  failed. */
  inventories: Record<string, EditorInventory>;
  /** What every installed skill declares at `scope`, and where this
   *  place's settings file stands on each key. Null where the read has
   *  not landed or failed — never an empty answer standing in for one. */
  settings: ScopeSettings | null;
  /** Settings values changed here and not yet written: the second draft
   *  the one Save bar carries, alongside the manifest. */
  settingsEdits: SettingsEdit[];
  /** Every scope's settings read, keyed by scope — the settings half of
   *  the same marks `saved` answers the manifest half of. */
  savedSettings: Record<string, ScopeSettings>;
  /** Either draft holds unsaved work. */
  dirty: boolean;
  /** The manifest half alone. A save carries the manifest only when it
   *  was edited: reconciling a settings change must not rewrite a
   *  hand-formatted kendex.toml nobody touched. */
  manifestDirty: boolean;
  loading: boolean;
  saving: boolean;
  error: string | null;
  /** The save was refused because the file changed outside this draft.
   *  The way out is the reload the page offers, not a retry. */
  stale: boolean;
  setScope: (scope: Scope) => Promise<void>;
  /** Point the editor at a scope without discarding edits already in hand. */
  openScope: (scope: Scope) => Promise<void>;
  load: () => Promise<void>;
  /** Read every scope's manifest and settings, for the marks drawn
   *  outside the editor. */
  loadAll: () => Promise<void>;
  /** Read named places only, merged into what is already read. A page
   *  about one package needs the places that package sits in and nothing
   *  else — asking for every scope would put the machine's whole project
   *  list behind one package's mark. */
  loadPlaces: (scopes: Scope[]) => Promise<void>;
  edit: (change: (draft: Draft) => Draft) => void;
  /** Set or reset one package setting, replacing any earlier answer for
   *  the same key of the same skill. */
  editSetting: (edit: SettingsEdit) => void;
  save: () => Promise<void>;
}

export const useEditorStore = create<EditorState>((set, get) => {
  const load = async () => {
    const { scope } = get();
    set({ loading: true });
    let read: Awaited<ReturnType<typeof readPlace>>;
    try {
      read = await readPlace(scope);
    } finally {
      set({ loading: false });
    }
    const [manifest, inventory, settings] = read;
    const draft = readDraft(manifest);
    // The records answer for the place, whichever place the editor is on
    // now: what this read saw is what that place held.
    set(recordedRead(scope, read));
    // The page's own copy is another matter. Committed into a scope the
    // editor has since left, this read puts one project's rows under
    // another project's name — and with the two bases matching, which
    // both files being absent is enough for, the next save writes the
    // value on screen into the wrong project's settings file.
    if (!sameScope(get().scope, scope)) return;
    if (manifest.status === "error") {
      set({
        ...opening,
        draft: null,
        base: null,
        settings: null,
        error: manifest.error,
      });
      return;
    }
    set({
      ...opening,
      draft: draft ?? emptyDraft(),
      base: manifest.data.base,
      settings: settings.status === "ok" ? settings.data : null,
      error: readError(inventory, settings),
    });
  };

  /** Read the named places into the records the marks are drawn from. */
  const places = async (scopes: Scope[]) => {
    set(mergedPlaces(scopes, await placesOf(scopes)));
  };

  const write = async (draft: Draft) => {
    const { scope, base, manifestDirty, settingsEdits, settings } = get();
    set({ saving: true });
    let response: Awaited<ReturnType<typeof commands.saveCustomize>>;
    try {
      response = await commands.saveCustomize(
        scope,
        manifestDirty ? { manifest: draft, base } : null,
        settingsDraft(settingsEdits, settings),
      );
    } finally {
      set({ saving: false });
    }
    if (response.status === "error") {
      // Stale is a refusal, not a failure: the file changed outside this
      // draft, and writing the draft would put the older file back. The
      // draft cannot be merged, so the page offers the reload as a choice
      // rather than taking the person's edits on its own. A refusal with
      // something to say about the packages leaving answers `failed`
      // instead, so nothing it said is dropped for the reload.
      if (response.error.kind === "stale") {
        set({ stale: true, error: null });
      } else {
        set({ error: response.error.message, stale: false });
      }
      return;
    }
    set({ error: null, stale: false });
    // Saving a manifest that takes a package away owes the same account a
    // removal does. Wired here rather than by the write the update commands
    // share: the editor answers a refusal shape of its own and never goes
    // through it.
    saying(response);
    await load();
    // Forced: a save rewrote the manifest this scope renders from, so an
    // audit inside its freshness window would keep every score answering
    // for the files as they were before the edit.
    await useAuditStore.getState().refresh({ force: true });
    await useScanStore.getState().refresh();
  };

  return {
    scope: { scope: "global" },
    draft: null,
    base: null,
    saved: {},
    inventories: {},
    settings: null,
    settingsEdits: [],
    savedSettings: {},
    dirty: false,
    manifestDirty: false,
    loading: false,
    saving: false,
    error: null,
    stale: false,

    setScope: async (scope) => {
      set({
        ...opening,
        scope,
        draft: null,
        base: null,
        settings: null,
        error: null,
      });
      await load();
    },

    openScope: async (scope) => {
      const state = get();
      // Open means both halves landed. A manifest read that succeeded
      // beside a failed settings read leaves a page with no settings
      // controls that coming back never retries, and a skill installed
      // in one place has no other pill to switch to.
      if (state.draft && state.settings && sameScope(state.scope, scope))
        return;
      await state.setScope(scope);
    },

    load,

    loadAll: async () => {
      // Startup reads run side by side, so the project list may still be on
      // its way — without it this would mark only the global scope.
      const settings = useSettingsStore.getState();
      if (!settings.settings) await settings.load();
      const { projects = [] } = useSettingsStore.getState().settings ?? {};
      await places(everyPlace(projects));
    },

    loadPlaces: places,

    edit: (change) => {
      const { draft } = get();
      if (!draft) return;
      set({ draft: change(draft), dirty: true, manifestDirty: true });
    },

    editSetting: (edit) => {
      set((state) => ({
        settingsEdits: withEdit(state.settingsEdits, edit),
        dirty: true,
      }));
    },

    save: async () => {
      const { draft } = get();
      if (!draft) return;
      await write(draft);
    },
  };
});
