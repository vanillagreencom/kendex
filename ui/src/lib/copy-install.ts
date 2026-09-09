// The guided install, and the words it asks its two questions in.
//
// Every Install in the app opens this one flow: a package's page, a set's
// page, a row in a packages table, a selection of rows, and the Add
// packages a project's card offers. So the questions are asked once, here,
// and no surface invents its own wording for them.
//
// The model `copy-model.ts` states is what the questions are about: a
// package is installed into a place, and a place is the personal setup or
// a project.
export const INSTALL_TITLE = "Install";
export const INSTALL_HELP =
  "Choose what to install and which places get it. kendex writes the files and keeps them up to date.";

export const INSTALL_WHAT_LABEL = "What to install";
export const INSTALL_WHERE_LABEL = "Where it goes";
export const INSTALL_TOOLS_LABEL = "Tools";

/** How many packages an answer covers, said under the answer itself so a
 *  reader picking "everything here" knows what everything is. */
export const packageCount = (count: number): string =>
  `${count} package${count === 1 ? "" : "s"}`;

/** The three shapes of the what question. Each is one option's own words,
 *  so a dialog opened on one package and one opened on a selection read as
 *  the same question with different answers. */
export const justThisLabel = (name: string): string => `Just ${name}`;
export const selectedLabel = (count: number): string =>
  count === 1 ? "The one you picked" : `The ${count} you picked`;
export const EVERYTHING_HERE_LABEL = "Everything here";
/** The selection's one action, above the table. The count is on the button
 *  because that is what pressing it installs. */
export const installSelectedLabel = (count: number): string =>
  `Install ${count} selected`;
/** The header box, which is a control over every row rather than a row of
 *  its own, so it says what it reaches. */
export const SELECT_EVERY_ROW = "Select every package listed";
export const wholeSetLabel = (bundle: string): string =>
  `The whole ${bundle} set`;

/** What the outcome and the toast call the thing that was installed. */
export const justThisWhat = (name: string): string => name;
export const wholeSetWhat = (bundle: string): string => `the ${bundle} set`;

export const ALL_PROJECTS_LABEL = "All projects";
/** True of the list on screen, and of nothing else: a project added later
 *  is not reached by an install that ran before it existed. */
export const allProjectsHelp = (count: number): string =>
  `Every project on this list — ${count} of them.`;
export const NO_PROJECTS_TO_PICK =
  "You have no projects yet. Add one on Projects and it appears here.";
export const PERSONAL_PLACE_HELP = "Works in every project on this computer";

/** Only a personal subscription can send an install into another project;
 *  a marketplace a project owns installs where it lives. Said rather than
 *  shown as a picker with no choice left in it. */
export const installsWhereItLives = (places: string[]): string =>
  `These packages install in ${andList(places)}, where the marketplace they come from lives.`;

export const INSTALL_NO_PLACE = "Pick at least one place.";
/** The tools question changes what one install writes. Across several
 *  places there is no one answer — each place has its own tools — so the
 *  question is not asked and this says what happens instead. */
export const TOOLS_PER_PLACE = "Each place installs for the tools it has.";

export const INSTALL_ACTION = "Install";
export const INSTALLING_LABEL = "Installing…";
export const INSTALL_CANCEL = "Cancel";
export const INSTALL_DONE = "Done";

/** What happened, where. Named per place rather than as a count: the
 *  reader picked the places, and a number would not say which of them the
 *  files are actually in. */
export const installedIn = (what: string, places: string[]): string =>
  `Installed ${what} in ${andList(places)}.`;
export const installFailedIn = (what: string, places: string[]): string =>
  `Couldn't install ${what} in ${andList(places)}.`;
/** A place several marketplaces reach can take one package and refuse
 *  another. Neither of the two sentences above is true of it: one denies
 *  the files that are in, the other claims the ones that are not. */
export const installedPartlyIn = (what: string, places: string[]): string =>
  `Only some of ${what} went into ${andList(places)}.`;
/** Why a place refused, said beside the place. The engine's own words —
 *  they are what the reader can act on. */
export const refusalLine = (place: string, reason: string): string =>
  `${place} — ${reason}`;
/** The way to the place that now has the package, named so the click is
 *  predictable from the words alone. */
export const openPlaceLabel = (place: string): string => `Open ${place}`;

/** "acme", "acme and beta", "acme, beta, and gamma" — the same shape
 *  `copy-projects.ts` uses for marketplaces, with "and" because every
 *  named place took part rather than one of them. */
export function andList(names: string[]): string {
  if (names.length < 3) return names.join(" and ");
  return `${names.slice(0, -1).join(", ")}, and ${names[names.length - 1]}`;
}

/** The Add packages a place offers, on its card and on an empty Library
 *  narrowed to it. The place is named because the button is a promise
 *  about where the install lands. */
export const ADD_PACKAGES_LABEL = "Add packages";
export const addPackagesTo = (place: string): string =>
  `Add packages to ${place}`;
/** What an empty place says before it offers that button. */
export const nothingInstalledIn = (place: string): string =>
  `Nothing is installed in ${place} yet.`;
export const ADD_PACKAGES_HELP = "Browse packages and install them here.";
