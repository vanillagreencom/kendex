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
import { askingAgain, forgetRoot, isForgotten } from "@/lib/forgotten-roots";
import { rescanEverything } from "@/lib/rescan";
import { useAuditStore } from "./audit";
import { useScanStore } from "./scan";

interface ProjectSetupState {
  /** The root of the project most recently registered, as the registry
   *  recorded it. What "after choosing the folder, offer a template"
   *  needs: the canonical root the write returned, never the string
   *  somebody typed. Cleared once the offer it is for has been answered.
   */
  justAdded: string | null;
  clearJustAdded: () => void;
  /** Roots whose read of the machine has not answered yet. */
  checking: readonly string[];
  /** Roots that were registered and whose read failed. Cleared when a
   *  later read for that root answers. */
  unchecked: readonly string[];
  /** Read the machine again on this root's behalf, and record how it
   *  went. Not awaited by the registration that starts it: the project is
   *  a place the moment the registry says so, and the reader is taken
   *  back to it while this runs.
   *
   *  `registered` says this read follows a registration, which is what
   *  sets [`justAdded`]. The card's own Try again calls this too and does
   *  not pass it: a retry of a failed scan on a project kendex already
   *  tracks is not an addition, and treating it as one opened the
   *  install-a-template offer on a project nobody had just added. */
  check: (root: string, registered?: boolean) => Promise<void>;
  /** Drop what is held about one folder. A read still out for it answers
   *  about a place nothing tracks, and the card at the folder it moved to
   *  must not inherit "package check failed" from the path it left. */
  forget: (root: string) => void;
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
  justAdded: null,
  checking: [],
  unchecked: [],

  clearJustAdded: () => set({ justAdded: null }),

  forget: (root) => {
    // Said where every store that holds something per project says it: the
    // read below is not awaited by whoever started it, so its `finally`
    // can land after this and put the failure back.
    forgetRoot(root);
    set((state) => ({
      checking: without(state.checking, root),
      unchecked: without(state.unchecked, root),
      // The offer named this folder, and the folder is not a project any
      // more: nothing here is left naming it, which is this verb's whole
      // rule. An offer kept over it would ask to install into a place
      // nothing tracks.
      justAdded: state.justAdded === root ? null : state.justAdded,
    }));
  },

  check: async (root, registered = false) => {
    // Asking about a folder is what makes it a project again: the same
    // folder registered afresh reads here like any other.
    askingAgain([root]);
    set((state) => ({
      ...(registered ? { justAdded: root } : {}),
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
      // A folder that stopped being a project while this was out gets no
      // state back from it: the reading is about a place nothing tracks,
      // and putting the failure back is the mark this read's own forget
      // took off.
      const stale = isForgotten(root);
      set((state) => ({
        checking: without(state.checking, root),
        // A read that answered read the whole machine, not this root — so
        // it answers for every root a previous read failed on too. Clearing
        // only its own would leave a project marked "package check failed"
        // over a reading that has since refreshed it, with a Try again that
        // does nothing new.
        // Three answers, not two. A read that answered clears every
        // root, since it read the whole machine. One that failed for a
        // root still tracked marks that root. One that failed for a
        // folder nobody tracks any more says nothing about any of them,
        // so every other project keeps the mark it had.
        unchecked: (() => {
          if (!failed) return [];
          return stale
            ? without(state.unchecked, root)
            : with_(state.unchecked, root);
        })(),
      }));
    }
  },
}));
