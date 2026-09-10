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
import {
  type Ask,
  commands,
  type ItemKind,
  type PackageSetup,
  type Scope,
} from "@/bindings";
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

/** A place's entry key. [`declaresSetup`] is why the kind is pinned rather
 *  than threaded through every call. */
const keyOf = (scope: Scope, name: string): string =>
  placeKey(SETUP_KIND, name, scope);

/** The one kind a repository effect can be declared by: a `repo-effects`
 *  block lives in a `SKILL.md`, and `engine::installed_declaration` reads
 *  the lock for skills alone.
 *
 *  Named here rather than assumed, because assuming it is how a page about
 *  an agent asks after a skill: names are unique per kind, not across
 *  them, so an agent and a skill may both be called `commit-guards` — and
 *  a page about the agent would then report, and offer to run, the skill's
 *  repository effect. */
const SETUP_KIND: ItemKind = "skill";

/** Whether a package of this kind can declare a repository effect at all.
 *  What a surface asks before starting a read: everything below is keyed
 *  by [`SETUP_KIND`], so a page about another kind must not ask. */
export const declaresSetup = (kind: ItemKind): boolean => kind === SETUP_KIND;

/** The latest read issued for each place, counted so a slower earlier one
 *  can tell it has been overtaken. Module state rather than store state:
 *  nothing renders from it, and a counter in the store would publish a
 *  change to every subscriber on each read. */
const issued: Record<string, number> = {};

export const usePackageSetupStore = create<PackageSetupState>((set, get) => ({
  entries: {},

  check: async (scope, name, ask = "surface") => {
    const key = keyOf(scope, name);
    // Which read this is for this place. Two effects drive these — the
    // page opening and the effects dialog closing — and a person can
    // press Check again over either, so two reads of one place can be out
    // together. Without this the slower one lands last and states a
    // repository as it stood before the write that prompted the second,
    // which is the stale answer the whole store exists to avoid.
    const token = (issued[key] ?? 0) + 1;
    issued[key] = token;
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
    // A read the place has moved past answers for nothing: its successor
    // is out and will say what is true now, and `reading` belongs to that
    // one. Dropped rather than merged — there is no half of a stale answer
    // worth keeping.
    if (issued[key] !== token) return;
    set((state) => ({
      entries: { ...state.entries, [key]: { setup, refused, reading: false } },
    }));
  },

  checkAll: async (scopes, name) => {
    await Promise.all(scopes.map((scope) => get().check(scope, name)));
  },

  forget: () => {
    // The reads still out belong to a package this store no longer holds,
    // so every place moves past them at once.
    for (const key of Object.keys(issued)) issued[key] += 1;
    set({ entries: {} });
  },
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
