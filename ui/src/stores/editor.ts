import { create } from "zustand";
import { commands, type EditorInventory, type Scope } from "@/bindings";
import { type Draft, emptyDraft, toDraft } from "@/lib/editor-draft";
import { sameScope, scopeKey } from "@/lib/scope";
import { useAuditStore } from "./audit";
import { manifestsOf, recorded } from "./editor-cache";
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
  dirty: boolean;
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
  /** Read every scope's manifest, for the marks drawn outside the editor. */
  loadAll: () => Promise<void>;
  /** Read the manifests of named places only, merged into what is already
   *  read. A page about one package needs the places that package sits in
   *  and nothing else — asking for every scope would put the machine's
   *  whole project list behind one package's mark. */
  loadPlaces: (scopes: Scope[]) => Promise<void>;
  edit: (change: (draft: Draft) => Draft) => void;
  save: () => Promise<void>;
}

export const useEditorStore = create<EditorState>((set, get) => {
  const load = async () => {
    const { scope } = get();
    set({ loading: true });
    let manifest: Awaited<ReturnType<typeof commands.getManifest>>;
    let inventory: Awaited<ReturnType<typeof commands.editorInventory>>;
    try {
      [manifest, inventory] = await Promise.all([
        commands.getManifest(scope),
        commands.editorInventory(scope),
      ]);
    } finally {
      set({ loading: false });
    }
    if (manifest.status === "error") {
      set((state) => ({
        draft: null,
        base: null,
        // This place has stopped reading, so what it last said goes with
        // it. Left in place, the mark would keep answering for this
        // package here out of a manifest that can no longer be read.
        saved: recorded(state.saved, scope, null),
        inventories: recorded(state.inventories, scope, null),
        dirty: false,
        stale: false,
        error: manifest.error,
      }));
      return;
    }
    // With no manifest here yet the editor still opens, on an empty one:
    // asking someone to press "create" before they can type is a step that
    // decides nothing. Saving is what writes the file.
    const draft = manifest.data.manifest
      ? toDraft(manifest.data.manifest)
      : emptyDraft();
    set((state) => ({
      draft,
      base: manifest.data.base,
      saved: recorded(state.saved, scope, draft),
      // An inventory that failed to read leaves this place without one,
      // rather than leaving the last place's on screen: the Skills section
      // would otherwise offer another place's assignment as this one's,
      // and a pick made from it writes a declaration nobody meant.
      inventories: recorded(
        state.inventories,
        scope,
        inventory.status === "ok" ? inventory.data : null,
      ),
      dirty: false,
      stale: false,
      error: inventory.status === "ok" ? null : inventory.error,
    }));
  };

  const write = async (draft: Draft) => {
    const { scope, base } = get();
    set({ saving: true });
    let response: Awaited<ReturnType<typeof commands.saveCustomize>>;
    try {
      response = await commands.saveCustomize(
        scope,
        { manifest: draft, base },
        null,
      );
    } finally {
      set({ saving: false });
    }
    if (response.status === "error") {
      // Stale is a refusal, not a failure: the file changed outside this
      // draft, and writing the draft would put the older file back. The
      // draft cannot be merged, so the page offers the reload as a choice
      // rather than taking the person's edits on its own.
      if (response.error.kind === "stale") {
        set({ stale: true, error: null });
      } else {
        set({ error: response.error.message, stale: false });
      }
      return;
    }
    set({ error: null, stale: false });
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
    dirty: false,
    loading: false,
    saving: false,
    error: null,
    stale: false,

    setScope: async (scope) => {
      set({
        scope,
        draft: null,
        base: null,
        dirty: false,
        error: null,
        stale: false,
      });
      await load();
    },

    openScope: async (scope) => {
      const state = get();
      if (state.draft && sameScope(state.scope, scope)) return;
      await state.setScope(scope);
    },

    load,

    loadAll: async () => {
      // Startup reads run side by side, so the project list may still be on
      // its way — without it this would mark only the global scope.
      const settings = useSettingsStore.getState();
      if (!settings.settings) await settings.load();
      const projects = useSettingsStore.getState().settings?.projects ?? [];
      const scopes: Scope[] = [
        { scope: "global" },
        ...projects.map((root) => ({ scope: "project" as const, root })),
      ];
      // Replaced, not merged: this is the whole list, so a scope that has
      // gone leaves with it.
      set({ saved: await manifestsOf(scopes) });
    },

    loadPlaces: async (scopes) => {
      const read = await manifestsOf(scopes);
      set((state) => ({
        saved: scopes.reduce(
          (saved, scope) => recorded(saved, scope, read[scopeKey(scope)]),
          state.saved,
        ),
      }));
    },

    edit: (change) => {
      const { draft } = get();
      if (!draft) return;
      set({ draft: change(draft), dirty: true });
    },

    save: async () => {
      const { draft } = get();
      if (!draft) return;
      await write(draft);
    },
  };
});
