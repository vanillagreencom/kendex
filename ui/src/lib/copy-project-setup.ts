// Adding a project, and finding the ones already on this machine.
//
// Two dialogs and the card they end at. Registration and the inventory
// check behind it are separate states with separate words: a project is
// added the moment the registry says so, and what it holds is a second
// answer that arrives later or fails on its own.
export const ADD_PROJECT_TITLE = "Add a project";
export const ADD_PROJECT_HELP =
  "Point kendex at a project folder and it keeps that project's tools in sync too.";
export const ADD_PROJECT_ACTION = "Add project";
/** While the registry write is out. Said as a state, not as a disabled
 *  button still reading "Add project": the press landed, and nothing on
 *  screen said so. */
export const ADDING_PROJECT = "Adding project…";
export const ADD_PROJECT_PLACEHOLDER = "/path/to/project";
export const ADD_PROJECT_BROWSE = "Browse for a project folder";

export const FIND_PROJECTS_TITLE = "Find existing projects";
/** Read before a folder is chosen, because it is what the choice means:
 *  the search reads and adds nothing by itself. */
export const FIND_PROJECTS_HELP =
  "kendex searches the folder you choose, and the folders inside it, for projects that already have coding-tool setup. It only reads; nothing is added until you say so.";
export const FIND_PROJECTS_ACTION = "Find projects";
export const FIND_PROJECTS_PLACEHOLDER = "/path/to/search";
export const FIND_PROJECTS_BROWSE = "Browse for a folder to search";
export const searchingIn = (root: string): string => `Searching ${root}…`;
export const foundProjects = (count: number): string =>
  `${count} project${count === 1 ? "" : "s"} found`;
/** Nothing matched, which is a result rather than a blank panel — and the
 *  folder itself may still be the project the reader meant. */
export const NO_PROJECTS_FOUND = "No projects in there.";
export const ADD_THIS_FOLDER = "Add this folder as a project";
/** The search failed. Never folded into the empty result: "none found" is
 *  a claim about the folder, and a folder kendex could not read supports
 *  no claim at all. */
export const searchFailed = (root: string): string =>
  `kendex couldn't search ${root}.`;
export const ALREADY_ADDED = "Already added";
export const ADD_LABEL = "Add";
export const ADDING_LABEL = "Adding…";

/** The card's second state: registered, and its contents still being read.
 *  Until this lands the card cannot say what is installed, and zero would
 *  be a checked result it has not got. */
export const CHECKING_PACKAGES = "Checking installed packages…";
/** The check failed. The project is added either way — that is what the
 *  first half of the sentence is for. */
export const CHECK_FAILED = "Project added; package check failed";
