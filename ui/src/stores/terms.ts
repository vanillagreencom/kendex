import { create } from "zustand";
import { commands, type TermsState } from "@/bindings";
import { settled } from "@/lib/settled";

interface TermsStoreState {
  /** Null until the first read lands. Nothing is asked on a null: a read
   *  that has not happened is no evidence that the person has not already
   *  accepted, and putting the screen up on it would ask someone who
   *  answered months ago. */
  state: TermsState | null;
  /** Why the accept did not go through, shown beside the button. */
  error: string | null;
  load: () => Promise<void>;
  accept: () => Promise<void>;
}

/**
 * Whether to ask about the terms, and what is on record.
 *
 * Both answers come from the backend, which reads them off the same
 * settings file the command line writes on its own first run. Nothing
 * here compares versions: the rule for when a later version asks again is
 * `kendex_core::legal`'s, and a copy of it in the UI would be a second
 * rule to keep in step.
 *
 * A read that failed asks nothing. The screen exists to record an answer,
 * and an app that cannot read its settings cannot write one either — so it
 * would be a wall with nothing behind it.
 */
export const useTermsStore = create<TermsStoreState>((set, get) => ({
  state: null,
  error: null,

  load: async () => {
    const read = await settled(commands.termsState());
    if (read.status === "ok") set({ state: read.data, error: null });
  },

  accept: async () => {
    if (get().state?.ask !== true) return;
    const written = await settled(commands.acceptTerms());
    if (written.status === "ok") set({ state: written.data, error: null });
    else set({ error: written.error });
  },
}));
