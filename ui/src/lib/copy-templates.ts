// The words the Templates surfaces use. Product prose, kept here so it can
// be read as writing rather than found across components.
//
// A template is a group of packages you save and install into any project.
// Every sentence below says what a control does; none of them says why a
// template is worth having.

/** The tab, the page title's second half, and the word for one of these
 *  wherever it is named. */
export const TEMPLATES_TAB = "Templates";
export const INSTALLED_TAB = "Installed";

/** Under the list, once, because a person meeting the tab has not met the
 *  idea. */
export const TEMPLATES_EXPLAINER =
  "A template is a group of packages you save and install into any project.";

export const TEMPLATES_EMPTY =
  "No templates yet. Create one from a project, or from packages you select in a marketplace.";
export const TEMPLATES_UNREADABLE = "Templates could not be read.";
export const TEMPLATES_LAST_KNOWN =
  "Templates could not be read. These are the last kendex could check.";
export const TEMPLATES_READING = "Reading your templates…";
export const TEMPLATES_SEARCH = "Search templates";
export const TEMPLATES_NONE_MATCH = "No template matches this search.";

export const packageCount = (count: number): string =>
  `${count} package${count === 1 ? "" : "s"}`;

/** The row's second line: how many packages, and how many of those the
 *  template keeps its own copy of. */
export const templateSummary = (packages: number, copies: number): string =>
  copies === 0
    ? packageCount(packages)
    : `${packageCount(packages)}, ${copies} copied into this template`;

export const CREATE_FROM_PROJECT_LABEL = "Create template…";
export const INSTALL_TEMPLATE_LABEL = "Install a template…";
export const ADD_TO_TEMPLATE_LABEL = "Add to template…";
export const NEW_TEMPLATE_LABEL = "Create template";
export const RENAME_TEMPLATE_LABEL = "Rename…";
export const DELETE_TEMPLATE_LABEL = "Delete…";
export const REMOVE_MEMBER_LABEL = "Remove from template";

/** The one sentence the issue fixes, said wherever a copy is about to be
 *  taken. */
export const COPIES_GO_INTO_THIS_TEMPLATE =
  "Copies go into this template. Files in this project stay unchanged.";

export const CREATE_FROM_PROJECT_TITLE = (project: string): string =>
  `Create a template from ${project}`;
export const TEMPLATE_NAME_LABEL = "Name";
export const INCLUDED_PACKAGES_LABEL = "Included packages";
export const INCLUDE_LOCAL_LABEL = "Include local packages";
export const INCLUDE_LOCAL_HELP =
  "Packages in this project that kendex does not manage. Selected ones are copied into the template.";
export const INCLUDE_CUSTOMIZATIONS_LABEL = "Include package customizations";
export const INCLUDE_CUSTOMIZATIONS_HELP =
  "Carry this project's settings for the included packages into the template.";
export const EXCLUDED_LABEL = "Left out";
export const DRAFT_READING = "Reading this project…";
export const DRAFT_UNREADABLE = "This project could not be read.";

/** A member the reader has to decide about before the template can be
 *  saved. */
export const CHOICE_LABEL = "Choose which copy to save";
/** The licence a marketplace's bytes come under, asked before they are
 *  copied. Confirming is only an answer for a licence kendex recognizes;
 *  anything else needs a stated reason. */
export const licenseUnder = (license: string): string =>
  `These files come from the marketplace under licence ${license}.`;
export const LICENSE_NONE =
  "The marketplace states no licence for these files.";
export const LICENSE_CONFIRM = "The licence permits copying these files";
export const LICENSE_BASIS_LABEL = "Your reason for copying them";
export const LICENSE_BASIS_HELP =
  "kendex does not recognize this licence as one that permits copying, so state the basis yourself.";
export const CHOICE_MARKETPLACE = "The marketplace package";
export const CHOICE_LOCAL = "This project's edited copy";
export const choiceHelp = (repo: string): string =>
  `This package came from ${repo} and was edited here. A template holds one of them.`;

export const UNRESOLVED_LABEL = "Cannot be saved yet";
export const RESOLVE_OR_EXCLUDE =
  "Resolve this, or clear its tick to leave it out.";

export const MEMBERS_HEADING = "Packages";
export const COPIES_HEADING = "Copied into this template";
export const MISSING_HEADING = "Not available";
export const FILES_HEADING = "Files this template owns";
export const NO_FILES = "This template holds no copies of its own.";
/** Said instead of the no-copies sentence when the read failed: nothing
 *  has answered, so no claim about what the template holds can be made. */
export const FILES_UNREADABLE =
  "The files this template owns could not be read.";
export const FILES_READING = "Reading the files this template owns…";
export const RESOLVE_READING = "Reading what this template installs…";
export const RESOLVE_UNREADABLE =
  "What this template installs could not be read.";
export const lastKnownVersion = (version: string): string =>
  `last known ${version}`;
export const notSubscribedYet = "installing subscribes to this marketplace";
/** What a saved revision actually does: it spells a fresh subscription
 *  and reaches nothing where one already exists, so the row says that
 *  rather than offering it as a version this install will pin. */
export const notSubscribedYetAt = (rev: string): string =>
  `installing subscribes to this marketplace at ${rev}`;
export const subscribedAs = (alias: string): string => `subscribed as ${alias}`;

export const DELETE_TITLE = (name: string): string => `Delete ${name}?`;
export const DELETE_BODY =
  "Packages already installed from this template stay installed. The template and the copies it owns are removed.";
export const DELETE_CONFIRM = "Delete template";

export const RENAME_TITLE = "Rename template";

export const ADD_TO_TEMPLATE_TITLE = "Add to a template";
export const ADD_TO_TEMPLATE_HELP =
  "Save the selected packages into a template you can install into any project.";
export const PICK_TEMPLATE_LABEL = "Template";
export const NEW_TEMPLATE_OPTION = "Create a template…";
export const addedToTemplate = (count: number, name: string): string =>
  `Added ${packageCount(count)} to ${name}.`;
/** Said when a ticked row carries no marketplace a template can record.
 *  Named rather than counted: the person picked those rows and is the
 *  only one who can pick different ones. */
export const droppedFromTemplate = (names: string[]): string =>
  `${names.join(", ")} ${names.length === 1 ? "is" : "are"} not in a subscribed marketplace, so a template cannot record ${names.length === 1 ? "it" : "them"}. Subscribe first, or untick ${names.length === 1 ? "it" : "them"}.`;

export const INSTALL_TEMPLATE_TITLE = "Install a template";
export const BROWSE_PACKAGES_LABEL = "Browse packages";
export const NO_TEMPLATES_TO_INSTALL =
  "No templates yet. Create one from a project, or from packages you select in a marketplace.";
