// The one guided install, as state.
//
// Every Install in the app opens this: a package's page, a set's page, a
// row or a selection of rows in a packages table, and the Add packages a
// place's card offers. Nothing else builds an install request, so the two
// questions — what, and where — are asked once and answered the same way
// wherever the reader started.
//
// Where is a list, not a pick: a package can go into several places in one
// action, which is what "all projects" is. `marketplace_install` writes
// into exactly one scope from exactly one subscription, so the run walks
// the chosen places and the marketplaces the choice spans, and reports the
// whole run once.
import { create } from "zustand";
import type {
  InstallItem,
  ItemKind,
  PackageDependencies,
  Scope,
} from "@/bindings";
import type { Choice } from "@/components/marketplaces/harness-select";
import { everyPlace, sameScope, scopeKey } from "@/lib/scope";
import { useMarketplacesStore } from "./marketplaces";
import { useNavStore } from "./nav";
import { useSettingsStore } from "./settings";
import { projectsOf } from "./settings-projects";

/** What one subscription contributes to an answer. A selection can span
 *  marketplaces — the cross-marketplace Packages tab lists them together —
 *  and one install command carries one source, so the answer is kept in
 *  the shape the command is sent in. */
export interface InstallGroup {
  source: string;
  /** The place that subscription is declared in. An install with no
   *  redirect lands here, and only a personal one may be redirected. */
  browsing: Scope;
  items: InstallItem[];
  /** A curated set installed as a set, which is not the same as installing
   *  its members: the set keeps itself whole. */
  bundle: string | null;
}

/** One answer to the what question: what it is called on screen, how many
 *  packages it covers, and the requests that install it. A surface
 *  offering a single answer states it as a sentence; two or more make it a
 *  choice. */
export interface InstallSubject {
  /** Stable across renders, and what the chosen answer is held by. */
  id: string;
  /** The option's own words, e.g. "Just command-safety". */
  label: string;
  /** What the outcome calls it afterwards, e.g. "command-safety" — the
   *  same thing named as an object rather than as a choice. */
  what: string;
  /** How many packages this answer installs. */
  count: number;
  groups: InstallGroup[];
  /** The kinds this answer declares, which decides which tools may take
   *  it. */
  kinds: ItemKind[];
  /** What one package says it needs, when the answer is one package. */
  dependencies?: PackageDependencies | null;
}

/** What a surface hands the flow when it opens it. */
export interface InstallAsk {
  subjects: InstallSubject[];
}

/** What the run did, per place. Kept apart from the ask so the dialog can
 *  report on a run whose ask has already been answered. */
export interface InstallOutcome {
  what: string;
  landed: Scope[];
  failed: Scope[];
}

/** Nothing answered about the tools yet, which is what leaves each place's
 *  own install defaults to decide. */
const NO_CHOICE: Choice = { harnesses: null, method: null, optional: [] };

interface InstallFlowState {
  /** What the open dialog is asking about, or null when it is closed. */
  ask: InstallAsk | null;
  /** Which of the ask's subjects is chosen. */
  subjectId: string;
  /** The places picked, in the order they are offered. */
  places: Scope[];
  choice: Choice;
  running: boolean;
  outcome: InstallOutcome | null;
  /** Open the flow on this ask. The place the reader came from is picked
   *  for them where one was carried — that is what makes "add a project,
   *  then add packages to it" one path rather than two. */
  open: (ask: InstallAsk) => void;
  close: () => void;
  chooseSubject: (id: string) => void;
  setPlaces: (places: Scope[]) => void;
  setChoice: (choice: Choice) => void;
  install: () => Promise<void>;
}

export const useInstallFlow = create<InstallFlowState>((set, get) => ({
  ask: null,
  subjectId: "",
  places: [],
  choice: NO_CHOICE,
  running: false,
  outcome: null,

  open: (ask) => {
    const subject = ask.subjects[0];
    set({
      ask,
      subjectId: subject?.id ?? "",
      places: subject ? openingPlaces(subject) : [],
      choice: NO_CHOICE,
      running: false,
      outcome: null,
    });
  },

  // The outcome goes with the ask: it is an account of a run against that
  // ask, and leaving it behind would head the next dialog with the last
  // install's result.
  close: () => set({ ask: null, outcome: null, running: false }),

  // Which tools can take an install is a fact about the place and about
  // what is being installed, so an answer given against either of the
  // others is not an answer here.
  chooseSubject: (subjectId) => {
    const subject = get().ask?.subjects.find((one) => one.id === subjectId);
    set({
      subjectId,
      choice: NO_CHOICE,
      ...(subject ? { places: openingPlaces(subject) } : {}),
    });
  },
  setPlaces: (places) => set({ places, choice: NO_CHOICE }),
  setChoice: (choice) => set({ choice }),

  install: async () => {
    const { ask, subjectId, places, choice, running } = get();
    if (!ask || running || places.length === 0) return;
    const subject =
      ask.subjects.find((one) => one.id === subjectId) ?? ask.subjects[0];
    if (!subject) return;
    set({ running: true, outcome: null });
    const landed: Scope[] = [];
    const failed: Scope[] = [];
    try {
      // One place at a time, and one marketplace at a time inside it: the
      // command writes into exactly one scope from exactly one
      // subscription. A place that refuses must not take the places beside
      // it down with it — each is reported on its own below.
      for (const place of places) {
        let wrote = false;
        let refused = false;
        for (const group of subject.groups) {
          const destination = destinationFor(group, place);
          if (destination === undefined) continue;
          const ok = await useMarketplacesStore.getState().install({
            scope: group.browsing,
            source: group.source,
            items: group.items,
            bundle: group.bundle,
            destination,
            // The tools answer is about one place's tools. Asked only when
            // one place is picked — see `TOOLS_PER_PLACE` — so across
            // several it is left out and each place's own defaults decide.
            delivery: places.length === 1 ? choice : undefined,
            quiet: true,
          });
          if (ok) wrote = true;
          else refused = true;
        }
        // A place where every marketplace landed is a place that has the
        // packages; one where any refused is named as a failure, because
        // what the reader asked for is not all there.
        if (refused || !wrote) failed.push(place);
        else landed.push(place);
      }
    } finally {
      set({
        running: false,
        outcome: { what: subject.what, landed, failed },
      });
    }
  },
}));

/** How this group reaches this place: `null` to install where the
 *  subscription lives, a scope to redirect into, or `undefined` where the
 *  engine refuses the pair — only a personal subscription may be
 *  redirected, and only into a project. */
function destinationFor(
  group: InstallGroup,
  place: Scope,
): Scope | null | undefined {
  if (sameScope(group.browsing, place)) return null;
  if (group.browsing.scope !== "global" || place.scope !== "project")
    return undefined;
  return place;
}

/** Every place this answer may install into.
 *
 *  A choice made entirely of personal subscriptions can go anywhere: the
 *  personal setup, and each project, since `marketplace_install` redirects
 *  a personal subscription into a project. Anything else installs where
 *  its subscription lives, so the places are those and the where question
 *  has no choice left in it. */
export function installablePlaces(
  subject: InstallSubject,
  projects: string[],
): Scope[] {
  if (subject.groups.every((group) => group.browsing.scope === "global"))
    return everyPlace(projects);
  const seen = new Map<string, Scope>();
  for (const group of subject.groups)
    seen.set(scopeKey(group.browsing), group.browsing);
  return [...seen.values()];
}

/** Whether the where question has an answer for the reader to give. */
export const placeIsAChoice = (subject: InstallSubject): boolean =>
  subject.groups.every((group) => group.browsing.scope === "global");

/** The places a freshly opened flow starts on: the one the reader came
 *  from where this answer can reach it, else everywhere it can only go. */
function openingPlaces(subject: InstallSubject): Scope[] {
  const offered = installablePlaces(
    subject,
    projectsOf(useSettingsStore.getState()),
  );
  if (!placeIsAChoice(subject)) return offered;
  const came = useNavStore.getState().installInto;
  const carried =
    came && offered.find((place) => sameScope(place, came)) ? came : offered[0];
  return carried ? [carried] : [];
}

/** Whether this place is among those picked. */
export const picked = (places: Scope[], place: Scope): boolean =>
  places.some((one) => sameScope(one, place));

/** The picked list with `place` added or taken out, kept in the order the
 *  places are offered so the dialog never reorders itself under a tick. */
export const togglePlace = (
  offered: Scope[],
  places: Scope[],
  place: Scope,
): Scope[] => {
  const wanted = new Set(places.map(scopeKey));
  if (wanted.has(scopeKey(place))) wanted.delete(scopeKey(place));
  else wanted.add(scopeKey(place));
  return offered.filter((one) => wanted.has(scopeKey(one)));
};
