// A project whose folder kendex cannot read, and pointing it at the folder
// the project moved to.
//
// One vocabulary for both halves: the card says what it could not read and
// what can be done about it, and the dialog says what the folder somebody
// picked turned out to hold. Neither claims the project is empty — a place
// that could not be read supports no count at all.
import type { MissingProject, MissingWhy, Standing } from "@/bindings";

/** The badge beside the project's name. Three readings, because they have
 *  three different answers: a folder that moved is reconnected, a path
 *  something else took is not, and a folder this machine cannot read may
 *  be readable in a moment. */
export const missingBadge = (why: MissingWhy): string => {
  switch (why.kind) {
    case "gone":
      return "Folder not found";
    case "not-a-folder":
      return "Not a folder";
    case "unreadable":
      return "Folder can't be read";
  }
};

/** Where the card's package counts would be. Said as what kendex cannot
 *  do rather than as a count, because there is no count: the folder is
 *  what it would have been read from. */
export const missingLead = (why: MissingWhy): string => {
  switch (why.kind) {
    case "gone":
      return "This folder isn't there, so kendex can't check the packages or setup here.";
    case "not-a-folder":
      return "This path isn't a folder, so kendex can't check the packages or setup here.";
    case "unreadable":
      return "kendex can't read this folder, so it can't check the packages or setup here.";
  }
};

/** The system's own words for why the folder could not be read, where it
 *  had any. Kept apart from the sentence above so the reading a person
 *  acts on is not a paraphrase. */
export const missingSaid = (why: MissingWhy): string | null =>
  why.kind === "unreadable" ? why.said : null;

export const LOCATE_FOLDER_LABEL = "Locate folder";
/** The same errand from a card whose folder reads fine: the recorded path
 *  existing is not proof it is still the project, because something else
 *  can have been created there since. */
export const CHANGE_FOLDER_LABEL = "Change folder…";
export const REMOVE_FROM_LIST_LABEL = "Remove from list";
/** On the menu, where the action is named away from its own card and two
 *  projects can end in the same folder. */
export const removeFromList = (name: string): string =>
  `Remove ${name} from list…`;
export const removeFromListTitle = (name: string): string =>
  `Remove ${name} from the list?`;
export const REMOVE_FROM_LIST_BODY =
  "kendex stops managing this project. Nothing in the folder is deleted.";

/** Home's line about the same state. It names the way out that the
 *  Projects page now has — a folder that moved is reconnected there, not
 *  added again as a second project. */
export const missingProjectsTitle = (count: number): string =>
  count === 1
    ? "1 project folder can't be read"
    : `${count} project folders can't be read`;
export const missingProjectDetail = (missing: MissingProject): string =>
  `${missingBadge(missing.why)}: ${missing.root}. Open Projects to point it at the folder it is in now.`;
export const MISSING_PROJECTS_DETAIL =
  "Open Projects to point each one at the folder it is in now.";

export const LOCATE_TITLE = "Locate folder";
export const locateHelp = (name: string): string =>
  `Choose the folder ${name} is in now. kendex points the project at it and keeps everything installed there. Nothing in either folder is moved, changed or deleted.`;
export const LOCATE_RECORDED = "Recorded folder";
export const LOCATE_PICKED = "New folder";
export const LOCATE_CHOOSE_ANOTHER = "Choose a different folder";
export const LOCATE_CONFIRM = "Reconnect project";
export const LOCATE_JOIN = "Join the two entries";
export const LOCATING = "Reconnecting…";
export const CHECKING_FOLDER = "Checking the folder…";

/** What the folder turned out to hold, in the words the person needs to
 *  decide. Every reading is here, including the ones that refuse: a folder
 *  kendex will not reconnect to has to say why, and "invalid" is not a
 *  reason anybody can act on. */
export const standingSaid = (standing: Standing, name: string): string => {
  switch (standing.kind) {
    case "moved":
      return `This folder holds ${name}'s packages and setup. Reconnecting keeps all of it.`;
    case "settled":
      return `This folder holds a kendex setup of its own. Reconnecting points ${name} at it and keeps everything in it.`;
    case "no-record":
      return "kendex has installed nothing in this folder. Reconnecting moves the project's entry and nothing else.";
    case "registered":
      return "kendex already tracks this folder as a project of its own. Joining the two leaves one project here; no folder and no file is deleted.";
    case "unchanged":
      return `This is the folder ${name} already points at.`;
    case "record-elsewhere":
      return `This folder belongs to another project — its setup was recorded under ${standing.root}. Choose the folder ${name} moved to.`;
    case "record-unreadable":
      return `kendex can't read the setup record in this folder, so it can't tell whose project it is: ${standing.said}`;
    case "folder-missing":
      return `kendex can't read that folder: ${standing.said}`;
  }
};

export const reconnected = (name: string, root: string): string =>
  `${name} is now at ${root}.`;
/** After the reconnect, what the fresh read of that place found. The
 *  reconnect does not repair anything, so what is left to do is named and
 *  left where the app already offers it. */
export const RECONNECT_CLEAN = "kendex found nothing else to fix here.";
export const reconnectProblems = (count: number): string =>
  count === 1
    ? "1 thing here still needs attention."
    : `${count} things here still need attention.`;
export const RECONNECT_UNCHECKED =
  "kendex hasn't been able to check this folder yet.";
export const SEE_PROBLEMS = "See problems";
export const CLOSE_LABEL = "Close";
