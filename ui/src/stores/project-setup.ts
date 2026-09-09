// What a freshly added project holds, read after it is added.
//
// Registering a project and knowing what is installed in it are two
// different answers arriving at two different times. The registry write is
// a settings save and lands in a moment; reading the machine again is
// seconds of work over every place, and it can fail on its own. Holding
// the add dialog open behind the second one is what made adding a project
// look frozen.
//
// So the states are kept apart here: a root is registered, then checking,
// then either checked — its counts are simply on the card — or unchecked,
// which is a state the card names with a way to try again. Zero packages
// is never one of these: it is what a card would say while the read that
// would have found them is still out.
import { create } from "zustand";
import { rescanEverything } from "@/lib/rescan";
import { useAuditStore } from "./audit";
import { useScanStore } from "./scan";

interface ProjectSetupState {
  /** Roots whose read of the machine has not answered yet. */
  checking: readonly string[];
  /** Roots that were registered and whose read failed. Cleared when a
   *  later read for that root answers. */
  unchecked: readonly string[];
  /** Read the machine again on this root's behalf, and record how it
   *  went. Not awaited by the registration that starts it: the project is
   *  a place the moment the registry says so, and the reader is taken
   *  back to it while this runs. */
  check: (root: string) => Promise<void>;
}

const without = (roots: readonly string[], root: string): string[] =>
  roots.filter((one) => one !== root);
const with_ = (roots: readonly string[], root: string): string[] =>
  roots.includes(root) ? [...roots] : [...roots, root];

/** Whether the reads a card draws from answered. The scan gives the card
 *  its counts and the audit gives it what is not managed; either failing
 *  leaves the card unable to say what is here, which is what the card
 *  reports rather than drawing an empty place. */
const readFailed = (): boolean =>
  useScanStore.getState().error !== null ||
  useAuditStore.getState().read.status === "failed";

export const useProjectSetupStore = create<ProjectSetupState>((set) => ({
  checking: [],
  unchecked: [],

  check: async (root) => {
    set((state) => ({
      checking: with_(state.checking, root),
      unchecked: without(state.unchecked, root),
    }));
    try {
      await rescanEverything();
    } finally {
      // Read after the reads have settled, from the stores that hold them:
      // `rescanEverything` answers with nothing, and a caller that decided
      // from its own return would be deciding from silence.
      const failed = readFailed();
      set((state) => ({
        checking: without(state.checking, root),
        unchecked: failed
          ? with_(state.unchecked, root)
          : without(state.unchecked, root),
      }));
    }
  },
}));
