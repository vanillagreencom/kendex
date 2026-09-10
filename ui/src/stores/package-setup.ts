// What one package's declared setup is doing in each project it is
// installed in.
//
// Kept apart from the places store because it is a different kind of
// answer. Where a package is installed and when it landed are reads of
// kendex's own records; whether its effect is in force is a question only
// the package can answer, and answering it can mean running the package's
// own script. So this store never joins a whole-machine rescan: it reads
// the places a page is actually showing, when that page asks, and when a
// write has just been answered for.
//
// One entry per place, keyed the way every other per-place cache is. A
// place that has not been read has no entry, which is what the row draws
// its checking state from — an absent answer is never an inactive one.
import { create } from "zustand";
import { type Ask, commands, type PackageSetup, type Scope } from "@/bindings";
import { placeKey } from "@/lib/package-places";

/** One place's last answer, or the fact that its read is out.
 *
 *  `reading` rides beside the answer rather than replacing it: a re-check
 *  after an operation keeps the previous state on screen with the spinner
 *  over it, and blanking it would flash "Not active" over a project that
 *  is about to report Active.
 *
 *  `refused` is why the command could not answer, kept rather than folded
 *  into a bare null. It is the cause the row prints: a project whose
 *  installed declaration will not read refuses while its siblings answer
 *  normally, and a row saying only "could not check" leaves the one person
 *  who can fix it with nothing to go on. */
export interface SetupEntry {
  setup: PackageSetup | null;
  refused: string | null;
  reading: boolean;
}

interface PackageSetupState {
  entries: Record<string, SetupEntry>;
  /** Read one place's setup. Nothing is cached between calls: the answer
   *  is a fact about a repository somebody else can change, and a page
   *  showing a retained one would state a repository as it stood before
   *  the change.
   *
   *  `ask` says who wants it, and the backend decides from it whether the
   *  package's own script may run. A page drawing itself sends `surface`;
   *  the control a person presses sends `person`, which is their licence
   *  to have the package asked directly. */
  check: (scope: Scope, name: string, ask?: Ask) => Promise<void>;
  /** Read every place in `scopes`, in parallel. What a page calls when it
   *  opens and after a write it started has been answered for — always as
   *  a surface, because nobody pressed anything. */
  checkAll: (scopes: Scope[], name: string) => Promise<void>;
  /** Drop every entry for a package other than this one's places. Called
   *  when the page moves to another package, so a card can never draw the
   *  previous package's state under this one's name. */
  forget: () => void;
}

/** A place's entry key. The kind is a skill wherever an effect is
 *  declared — a `repo-effects` block lives in a `SKILL.md` — so the key is
 *  built with the same helper every other per-place cache uses, and the
 *  kind is pinned rather than threaded through every call. */
const keyOf = (scope: Scope, name: string): string =>
  placeKey("skill", name, scope);

export const usePackageSetupStore = create<PackageSetupState>((set, get) => ({
  entries: {},

  check: async (scope, name, ask = "surface") => {
    const key = keyOf(scope, name);
    set((state) => ({
      entries: {
        ...state.entries,
        [key]: {
          setup: state.entries[key]?.setup ?? null,
          refused: state.entries[key]?.refused ?? null,
          reading: true,
        },
      },
    }));
    let setup: PackageSetup | null = null;
    let refused: string | null = null;
    try {
      const response = await commands.packageSetup(scope, name, ask);
      // A refusal leaves the place with no answer rather than the answer
      // it had: the command reads the declaration and the repository
      // together, so one that could not answer describes neither. Its
      // reason is kept, because it is the only account of why.
      if (response.status === "ok") setup = response.data;
      else refused = response.error;
    } catch (error) {
      // The wrapper folds a rejected command into an error status, so this
      // is the last guard rather than the first. A place nobody could
      // reach still says what stopped it.
      refused = error instanceof Error ? error.message : String(error);
    }
    set((state) => ({
      entries: { ...state.entries, [key]: { setup, refused, reading: false } },
    }));
  },

  checkAll: async (scopes, name) => {
    await Promise.all(scopes.map((scope) => get().check(scope, name)));
  },

  forget: () => set({ entries: {} }),
}));

/** One place's entry as its row reads it: what was answered, and whether a
 *  read is out. A selector over the record rather than the record itself,
 *  so a row re-renders on its own place's answer and not on its
 *  neighbours'. */
export const setupAt = (
  entries: Record<string, SetupEntry>,
  scope: Scope,
  name: string,
): SetupEntry | undefined => entries[keyOf(scope, name)];
