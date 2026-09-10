// A package's setup in one project: what the state is called, and what
// each control does about it. Kept apart from the rest so the wording is
// reviewed as writing, the same as copy.ts.
//
// Nothing here explains what a package's effect means — the package's own
// summary says that, in its own words, and it is what the row prints. What
// this file words is kendex's half: which state this is, and what pressing
// each button will do.
import type { SetupState } from "@/bindings";

export const SETUP_CHECKING = "Checking…";
export const SETUP_ACTIVE = "Active";
export const SETUP_NOT_ACTIVE = "Not active";
export const SETUP_NEEDS_REPAIR = "Needs repair";
export const SETUP_COULD_NOT_CHECK = "Could not check";
export const SETUP_UNAVAILABLE = "Status unavailable";

export const ACTIVATE_LABEL = "Set up";
export const REPAIR_LABEL = "Repair";
export const CHECK_AGAIN_LABEL = "Check again";

/** What each state is called on screen. `notDeclared` never reaches a
 *  row — a package that changes nothing about the repository has no setup
 *  to report — and is worded rather than left to fall through, so a state
 *  drawn by mistake says something true. */
export const setupStateLabel = (state: SetupState | "checking"): string => {
  switch (state) {
    case "checking":
      return SETUP_CHECKING;
    case "active":
      return SETUP_ACTIVE;
    case "notActive":
      return SETUP_NOT_ACTIVE;
    case "needsRepair":
      return SETUP_NEEDS_REPAIR;
    case "couldNotCheck":
      return SETUP_COULD_NOT_CHECK;
    case "unavailable":
    case "notDeclared":
    // Neither reaches a row — a package that changes nothing about the
    // repository has no setup to report, and the personal place is not a
    // repository — but both are worded, so a state drawn by mistake says
    // something true rather than nothing at all.
    case "notARepository":
      return SETUP_UNAVAILABLE;
  }
};

/** The one sentence under the state, where there is something to say
 *  that the state's own word does not carry. The package's own words are
 *  printed beside this rather than in place of it: this half says what
 *  kendex did, and the package's half says what it found.
 *
 *  One sentence per state and not two. `Not active` earned a second line
 *  saying why the check had not been run, and the pair read as the same
 *  fact twice - so the reason sits inside the sentence, which is where a
 *  person meets it before pressing the button that does the asking. */
export const setupStateNote = (
  state: SetupState | "checking",
): string | null => {
  switch (state) {
    case "checking":
    case "active":
      return null;
    case "notActive":
      return "Nothing on this machine has set this up here, so the package's check has not been run. Check again asks the package directly.";
    case "needsRepair":
      return "This was set up here and has stopped working.";
    case "couldNotCheck":
      return "The state could not be read. Nothing was changed.";
    case "unavailable":
    case "notDeclared":
      return "This package cannot report whether its setup is working. You can still set it up.";
    case "notARepository":
      return "Your personal setup is not a repository, so there is nothing here to set up.";
  }
};

/** What every work tree of the repository shares, said where the package
 *  writes into the common git directory. A linked work tree reports the
 *  state its whole repository is in, and setting it up here sets it up for
 *  all of them.
 *
 *  Printed only beside a control that would change it. On a row with
 *  nothing to press it is a fact nobody is about to act on, and a row
 *  saying four things is a row nobody reads. */
export const SETUP_SHARED_NOTE =
  "Every work tree of this repository shares this. Setting it up here changes it for all of them.";

export const setupHeading = (place: string): string => `Setup in ${place}`;
/** What each control is called to a screen reader. Every card carries the
 *  same word on its buttons, and read on their own nothing says which
 *  project the click reaches. The visible label stays the first word. */
export const activateInLabel = (place: string): string => `Set up in ${place}`;
export const repairInLabel = (place: string): string => `Repair in ${place}`;
export const checkAgainInLabel = (place: string): string =>
  `Check again in ${place}`;

/** Adding this package to a project that lacks it. One link into the
 *  guided install, which is where the project is picked: this tab lists
 *  the places the package is in, never every project on the machine.
 *
 *  Absent rather than explained where the package's marketplace is not one
 *  this machine subscribes to for itself — the install would be refused,
 *  and a line about a control that is not there is noise on every page. */
export const INSTALL_ELSEWHERE_LABEL = "Install in a project";

/** The Overview summary, when one project needs setup. Named rather than
 *  counted where it is one project, because the name is what the reader
 *  goes and looks at. */
export const setupNeededSummary = (places: string[]): string => {
  if (places.length === 1) return `${places[0]} needs setup for this package.`;
  return `${places.length} projects need setup for this package.`;
};
export const SETUP_NEEDED_LINK = "Show me";
