// The words the Templates surfaces use. Product prose, kept here so it can
// be read as writing rather than found across components.
//
// A template is a group of packages you save and install into any project.
// Every sentence below says what a control does; none of them says why a
// template is worth having.
import type { MemberKind } from "@/bindings";
import { kindLabel } from "@/lib/labels";

/** The tab, the page title's second half, and the word for one of these
 *  wherever it is named. */
export const TEMPLATES_TAB = "Templates";
export const INSTALLED_TAB = "Installed";

/** Under the list, once, because a person meeting the tab has not met the
 *  idea. */
export const TEMPLATES_EXPLAINER =
  "A template is a group of packages you save and install into any project.";

export const TEMPLATES_EMPTY =
  "No templates yet. Create one from a project's menu on Projects, or select packages in a marketplace and choose Add to template.";
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
export const INCLUDE_LOCAL_LABEL = "Include packages kendex does not manage";
export const INCLUDE_LOCAL_HELP =
  "kendex copies the ones you select into the template. It does not start managing the files in this project.";
export const INCLUDE_CUSTOMIZATIONS_LABEL = "Include package customizations";
export const INCLUDE_CUSTOMIZATIONS_HELP =
  "The template keeps what you customized for these packages in this project. Other project settings stay out.";
export const EXCLUDED_LABEL = "Can't be included";
export const DRAFT_READING = "Reading this project…";
export const DRAFT_UNREADABLE = "This project could not be read.";

/** A member the reader has to decide about before the template can be
 *  saved. */
export const CHOICE_LABEL = "Choose which files to save";
/** The license a marketplace's bytes come under, asked before they are
 *  copied. Confirming is only an answer for a license kendex recognizes;
 *  anything else needs a stated reason. */
export const licenseUnder = (license: string): string =>
  `The marketplace offers these files under the ${license} license.`;
export const LICENSE_NONE = "kendex found no license for these files.";
export const LICENSE_CONFIRM = "The license allows copying these files";
export const LICENSE_BASIS_LABEL = "Your reason for copying them";
export const LICENSE_BASIS_HELP =
  "kendex can't tell whether you may copy these files. Give your reason.";
export const CHOICE_MARKETPLACE = "Files from the marketplace";
export const CHOICE_LOCAL = "Edited files in this project";
export const choiceHelp = (repo: string): string =>
  `${repo} offers this package, and its files in this project are edited on disk. The template saves one of the two.`;

export const UNRESOLVED_LABEL = "Can't be saved";
export const RESOLVE_OR_EXCLUDE =
  "Clear its tick to leave it out, or fix the reason above and open this dialog again.";

export const COPIES_HEADING = "Copied into this template";
export const MISSING_HEADING = "Not available";
export const FILES_HEADING = "Files saved in this template";
export const NO_FILES =
  "This template has no files of its own. Every package installs from its marketplace.";
/** Said instead of the no-copies sentence when the read failed: nothing
 *  has answered, so no claim about what the template holds can be made. */
export const FILES_UNREADABLE =
  "The files saved in this template could not be read.";
export const FILES_READING = "Reading the files saved in this template…";
export const RESOLVE_READING = "Reading what this template installs…";
export const RESOLVE_UNREADABLE =
  "What this template installs could not be read.";
export const lastKnownVersion = (version: string): string =>
  `last known ${version}`;
export const notSubscribedYet = "Installing subscribes to this marketplace.";
/** What a saved revision actually does: it spells a fresh subscription
 *  and reaches nothing where one already exists, so the row says that
 *  rather than offering it as a version this install will pin. */
export const notSubscribedYetAt = (rev: string): string =>
  `Installing subscribes to this marketplace at version ${rev}.`;
export const subscribedAs = (alias: string): string =>
  `Subscribed under the short name ${alias}`;

export const DELETE_TITLE = (name: string): string => `Delete ${name}?`;
export const DELETE_BODY =
  "Packages installed from this template stay installed. kendex deletes the template and the files saved in it.";
export const DELETE_CONFIRM = "Delete template";

export const RENAME_TITLE = "Rename template";

export const ADD_TO_TEMPLATE_TITLE = "Add to a template";
export const ADD_TO_TEMPLATE_HELP =
  "Save the selected packages into a template you can install into any project.";
export const PICK_TEMPLATE_LABEL = "Template";
export const NEW_TEMPLATE_OPTION = "New template";
export const addedToTemplate = (count: number, name: string): string =>
  `Added ${packageCount(count)} to ${name}.`;
/** Said when a ticked row carries no marketplace a template can record.
 *  Named rather than counted: the person picked those rows and is the
 *  only one who can pick different ones. */
export const droppedFromTemplate = (names: string[]): string =>
  `${names.join(", ")} ${names.length === 1 ? "is" : "are"} not from a subscribed marketplace, so a template can't save ${names.length === 1 ? "it" : "them"}. Subscribe to the marketplace first, or clear ${names.length === 1 ? "its tick" : "their ticks"}.`;

export const INSTALL_TEMPLATE_TITLE = "Install a template";
export const BROWSE_PACKAGES_LABEL = "Browse packages";

/** A member that stays in the template but is switched off, said after
 *  its kind on one line. */
export const SWITCHED_OFF = "switched off";
/** The installed packages a member comes in for. */
export const neededBy = (names: string[]): string =>
  `needed by ${names.join(", ")}`;
/** A member the template saved from a project's edited files. */
export const editedFilesFrom = (repo: string): string =>
  `edited files from ${repo}`;
/** A member's kind as the rest of the app names kinds. A bundle is the one
 *  member kind that is not a package kind. */
export const memberKindLabel = (kind: MemberKind): string =>
  kind === "bundle" ? "Bundle" : kindLabel(kind);
