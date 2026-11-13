// The Mine tab's state: the marketplaces the user authors, the create /
// use-existing flows, the two optional offers, and the import wizard.
import { create } from "zustand";
import {
  type CreateRequest,
  commands,
  type ImportCandidate,
  type ImportOutcome,
  type ImportSelection,
  type MineListRow,
} from "@/bindings";

interface MineState {
  rows: MineListRow[] | null;
  loading: boolean;
  error: string | null;
  /** The last dialog action's refusal — shown inside the dialog it came
   * from, never on another page. */
  actionError: string | null;
  busy: boolean;

  candidates: ImportCandidate[] | null;
  outcome: ImportOutcome | null;

  load: () => Promise<void>;
  createMarketplace: (request: CreateRequest) => Promise<boolean>;
  useExisting: (path: string) => Promise<boolean>;
  forget: (path: string) => Promise<void>;
  acceptManifest: (
    path: string,
    name: string,
    description: string,
    author: string,
  ) => Promise<boolean>;
  acceptWorkflow: (path: string) => Promise<boolean>;
  loadInventory: () => Promise<void>;
  applyImport: (
    target: string,
    selections: ImportSelection[],
  ) => Promise<boolean>;
  clearAction: () => void;
}

export const useMineStore = create<MineState>((set, get) => ({
  rows: null,
  loading: false,
  error: null,
  actionError: null,
  busy: false,
  candidates: null,
  outcome: null,

  load: async () => {
    set({ loading: true });
    try {
      const rows = await commands.mineList();
      if (rows.status === "ok") set({ rows: rows.data, error: null });
      else set({ error: rows.error });
    } finally {
      set({ loading: false });
    }
  },

  createMarketplace: async (request) => {
    set({ busy: true, actionError: null });
    try {
      const made = await commands.mineCreate(request);
      if (made.status === "error") {
        set({ actionError: made.error });
        return false;
      }
      await get().load();
      return true;
    } finally {
      set({ busy: false });
    }
  },

  useExisting: async (path) => {
    set({ busy: true, actionError: null });
    try {
      const row = await commands.mineUseExisting(path);
      if (row.status === "error") {
        set({ actionError: row.error });
        return false;
      }
      await get().load();
      return true;
    } finally {
      set({ busy: false });
    }
  },

  forget: async (path) => {
    await commands.mineForget(path);
    await get().load();
  },

  acceptManifest: async (path, name, description, author) => {
    set({ busy: true, actionError: null });
    try {
      const accepted = await commands.mineAcceptManifest(
        path,
        name,
        description,
        author,
      );
      if (accepted.status === "error") {
        set({ actionError: accepted.error });
        return false;
      }
      await get().load();
      return true;
    } finally {
      set({ busy: false });
    }
  },

  acceptWorkflow: async (path) => {
    set({ busy: true, actionError: null });
    try {
      const accepted = await commands.mineAcceptWorkflow(path);
      if (accepted.status === "error") {
        set({ actionError: accepted.error });
        return false;
      }
      await get().load();
      return true;
    } finally {
      set({ busy: false });
    }
  },

  loadInventory: async () => {
    set({ candidates: null, outcome: null, actionError: null });
    const inventory = await commands.mineImportInventory();
    if (inventory.status === "ok") set({ candidates: inventory.data });
    else set({ actionError: inventory.error });
  },

  applyImport: async (target, selections) => {
    set({ busy: true, actionError: null });
    try {
      const outcome = await commands.mineImportApply(target, selections);
      if (outcome.status === "error") {
        set({ actionError: outcome.error });
        return false;
      }
      set({ outcome: outcome.data });
      await get().load();
      return true;
    } finally {
      set({ busy: false });
    }
  },

  clearAction: () => set({ actionError: null, outcome: null }),
}));
