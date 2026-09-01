import type { HarnessId } from "@/bindings";
import { harnessName } from "@/lib/labels";
// Product prose: the sentences a person reads, as opposed to the vocabulary
// in labels.ts that names things. Kept apart so wording can be reviewed as
// writing, in one place, without wading through id-to-name maps.
//
// House style, applied throughout:
//   - Say what happened or what will happen, not what the code calls it.
//   - Name the thing the person is looking at, not the internal concept.
//   - Never claim a state the app has not checked.
export const morePlacesLabel = (count: number): string =>
  `+${count} more place${count === 1 ? "" : "s"}`;

// What "managing" an item buys you, said once here so "Start managing"
// doesn't need to explain itself on every row, and used as the subtitle of
// the page that offers it. Says what you get, not what the app calls the
// state you'd be leaving.
export const UNMANAGED_SECTION_EXPLAINER =
  "Hand one over and kendex keeps it updated, checked and copied to every harness.";
export const START_MANAGING_LABEL = "Start managing";
// The one mention of unmanaged content anywhere in the app, on the card for
// the place holding it. It says what the click opens, not that anything is
// wrong: nothing here is a problem, and the offer is the user's to take.
export const unmanagedHereLabel = (count: number): string =>
  `${count} not managed yet`;
// Where that count would sit, for a place the audit could not read. Not a
// count and not a button: what is at the place is unknown, and every action
// the card could offer would come from a reading nothing confirmed. The kind
// counts beside it come from the scan and still hold, so this names the one
// thing that failed rather than the whole card.
export const PLACE_UNCHECKED_LABEL = "Couldn't check what's here";
export const PLACE_UNCHECKED_TITLE = "Couldn't check this place";
export const ALL_MANAGED_TITLE = "Everything is managed";
export const ALL_MANAGED_BODY =
  "kendex looks after everything it can see here.";
// Where a harness keeps its files — only worth setting for one that was
// moved somewhere other than its usual place.
// Content a harness ships with itself. It is named, never nagged about: the
// person never chose it and cannot change it from here.
export const bundledWithLabel = (harness: HarnessId): string =>
  `Bundled with ${harnessName(harness)}`;
export const vendorHelp = (vendor: string): string =>
  `${vendor} ships and updates this with the harness. kendex lists it, but doesn't manage or check it.`;
export const BROWSE_LABEL = "Choose a folder…";
export const HARNESS_FOLDER_HELP = "Change where this harness keeps its files";
export const harnessFolderTitle = (harness: string): string =>
  `Where does ${harness} keep its files?`;
export const HARNESS_FOLDER_BODY =
  "Only worth setting if you moved the harness. Leave it empty to let kendex find it.";
export const NOT_INSTALLED_LABEL = "Not installed";
export const startManagingAllLabel = (count: number): string =>
  `Start managing all ${count}`;
export const adoptedToastLabel = (name: string): string =>
  `Now managing ${name}`;

export const RECENT_ACTIVITY_EMPTY = "Nothing on this machine has changed yet.";

export const TAGS_ROW_LABEL = "For";

export const ADD_PROJECT_HELP =
  "Point kendex at a repository and it keeps that project's harnesses in sync too.";
export const SCAN_FOLDER_HELP =
  "Look inside a folder for repositories, then add the ones you want.";
export const NO_PROJECTS_FOUND = "Nothing that looks like a project in there.";

// The one toggle on an item. It was a button reading "Turn off", which said
// what the click does but never what the state is or what turning it off
// costs you — a switch shows the state, and the sentence under it says the
// files stay put.
export const ENABLED_LABEL = "Enabled";
export const ENABLED_HELP =
  "Your harnesses load this. Switch it off and the files stay where they are — they just stop reading them.";

// Library flyout's open-actions menu.
export const OPEN_IN_LABEL = "Open in…";
export const COPY_PATH_LABEL = "Copy path";
export const PATH_COPIED_TOAST = "Path copied";
export const OPEN_IN_FILE_BROWSER_LABEL = "File browser";
export const OPEN_IN_EDITOR_LABEL = "Editor";
export const EDITOR_ERROR_TITLE = "Couldn't open the editor";
export const EDITOR_ERROR_STEPS = [
  "Install VSCodium, VS Code, Cursor, Zed, or Sublime — or set KENDEX_EDITOR",
];
export const FILE_BROWSER_ERROR_TITLE = "Couldn't open the file browser";

export const BACK_LABEL = "Back";
export const WINDOW_CONTROL_LABELS = {
  minimize: "Minimize",
  maximize: "Maximize",
  close: "Close",
} as const;

// Home. A read that failed is an answer, not a wait: the page says what
// happened instead of holding skeletons up, and a result kept from before
// a failed re-scan is drawn as last-known rather than current.
export const SCAN_AGAIN_LABEL = "Scan again";
export const SCAN_FAILED_TITLE = "Couldn't scan this machine";
export const SCAN_STALE_TITLE = "These are the last figures kendex could check";
export const UPDATES_ATTENTION_TITLE = "Couldn't check for updates";
export const UPDATES_ATTENTION_DETAIL =
  "Anything new since the last check isn't counted here.";
export const AUDIT_ATTENTION_TITLE = "Couldn't check installed content";
export const AUDIT_ATTENTION_DETAIL =
  "Problems and pending changes may be missing here.";
export const TRY_AGAIN_LABEL = "Try again";

// Package page: files, versions, and the diff between them.
export const PACKAGE_FILES_TITLE = "Files";
export const PACKAGE_VERSION_TITLE = "Version";
export const README_TAG = "readme";
export const UPDATE_LABEL = "Update";
export const PREVIEW_CHANGES_LABEL = "Preview changes";
export const SWITCH_VERSION_LABEL = "Switch to this version";
export const COMPARE_WITH_INSTALLED_LABEL = "Compare with installed";
export const FOLLOW_SOURCE_LABEL = "Follow the source again";
export const INSTALLED_VERSION_TAG = "installed";
export const HELD_VERSION_TAG = "held here";
export const NO_VERSIONS_NOTE =
  "No version history yet — refresh the source to fetch it.";
export const BACK_TO_FILES_LABEL = "Back to files";
export const DIFF_TRUNCATED_NOTE =
  "This comparison is long; only the first part is shown.";
export const VERSION_ERROR_TITLE = "Couldn't switch versions";

// Updates page.
export const UPDATES_EMPTY = "Everything is up to date";
export const UPDATES_EMPTY_BODY =
  "Every package you installed is on its latest version.";
export const UPDATES_UNCHECKED_TITLE = "Couldn't be checked";
export const REMOVED_UPSTREAM_TAG = "No longer in its source";
export const UPDATE_ALL_LABEL = "Update all";
export const CHECK_FOR_UPDATES_LABEL = "Check for updates";
export const IGNORE_UPDATES_LABEL = "Stop notifying…";
export const ignoreConfirmTitle = (name: string): string =>
  `Stop notifying about ${name}?`;
export const IGNORE_CONFIRM_BODY =
  "It stays installed and can still be updated from its own page — it just leaves this list and the badge.";
export const IGNORE_CONFIRM_LABEL = "Stop notifying";
export const NOTIFY_AGAIN_LABEL = "Notify again";
export const hiddenUpdatesLabel = (count: number): string =>
  count === 1 ? "1 hidden update" : `${count} hidden updates`;
export const PINNED_UPDATE_TAG = "Held";
export const EDITED_UPDATE_TAG = "Edited by you";
export const UPDATE_ERROR_TITLE = "Couldn't update";
export const updatedToastLabel = (name: string): string => `Updated ${name}`;

// Fork: what happens when the app finds files you edited by hand.
export const FORKED_BADGE_LABEL = "Forked";
export const FORK_NOTICE_TITLE = "You've changed this package's files";
export const FORK_NOTICE_DETAIL =
  "Updates are paused so your edits stay. Keep it as your own copy, see what changed, or discard the edits and go back to the catalog's version.";
export const KEEP_AS_FORK_LABEL = "Keep as my own";
export const VIEW_CHANGES_LABEL = "View changes";
export const viewChangesInLabel = (tool: string): string =>
  `View changes in ${tool}`;
export const DISCARD_EDITS_LABEL = "Discard edits…";
export const DISCARD_ALL_EDITS_LABEL = "Discard all edits…";
export const editedInToolsLabel = (tools: string[]): string =>
  `Edited in ${tools.slice(0, -1).join(", ")} and ${tools.at(-1)}.`;
export const unforkableCopyNote = (tool: string): string =>
  `${tool}'s copy can't be kept as your own.`;
export const MULTI_TOOL_FORK_NOTE =
  "Keeping one tool's copy would drop the other edits, so the choice here is to discard them all.";
export const DERIVED_FORK_NOTE =
  "It came with a bundle or another package, so it can't become your own copy.";
export const DISCARD_EDITS_CONFIRM_TITLE = "Discard your edits?";
export const DISCARD_EDITS_CONFIRM_BODY =
  "The catalog's version replaces your edits to this package, and your changes are gone. Keep them as your own copy instead if you're unsure.";
export const DISCARD_EDITS_CONFIRM_LABEL = "Discard edits";
export const FORK_ERROR_TITLE = "Couldn't keep the edits";
export const forkedToastLabel = (name: string): string =>
  `${name} is yours now — updates are paused`;
export const forkedAttentionTitle = (count: number): string =>
  count === 1
    ? "You've edited an installed package"
    : `You've edited ${count} installed packages`;
export const FORKED_ATTENTION_DETAIL =
  "Your changes are safe — nothing will overwrite them. Decide whether to keep each as your own copy.";

export const FOLLOW_SOURCE_TOAST = "Now following its source";

// The app's own out-of-date notice, in the sidebar. It names both versions
// and offers the one action the install channel allows: a replacement where
// kendex owns the files, the package manager's own command where it does
// not, and nothing to press where nothing could tell.
export const APP_UPDATE_TITLE = "Update available";
export const appUpdateVersionsLabel = (
  latest: string,
  current: string,
): string => `kendex ${latest} is out. You have ${current}.`;
export const APP_UPDATE_INSTALL_LABEL = "Update now";
export const APP_UPDATE_INSTALLING_LABEL = "Updating…";
export const APP_UPDATE_NOTES_LABEL = "View release notes";
export const APP_UPDATE_DISMISS_LABEL = "Hide until the next version";
export const APP_UPDATE_MANAGED_NOTE = "Update it with:";
export const APP_UPDATE_UNKNOWN_NOTE =
  "Update kendex the way you installed it.";
// Said under Update now when the app is kendex's to replace and the
// `kendex` command beside it is not. The app moves and the command does
// not, so the card says that before the button is pressed rather than
// leaving a terminal on the old version with nothing having said so.
//
// It names the installer that owns the command, never a generic "your
// package manager": the detection knows which one it found, and the
// channel carries the name so nothing here has to read it back out of the
// command string.
export const appUpdateCommandManagedNote = (manager: string): string =>
  `Update now updates the app only. The kendex command was installed by ${manager}; update it with:`;
// Nothing could say who owns the command, so there is no installer to name
// and no command to offer. The same answer APP_UPDATE_UNKNOWN_NOTE gives
// for the app, about the command instead.
export const APP_UPDATE_COMMAND_UNKNOWN_NOTE =
  "Update now updates the app only. Update the kendex command the way you installed it.";
// Kendex's own command, sitting where this app cannot write. The offer is
// the installer, never a command aimed at a path an account can arrange.
export const appUpdateCommandPrivilegeNote = (path: string): string =>
  `Update now updates the app only. The kendex command at ${path} needs permissions this app does not have. The installer reinstalls kendex to the directory it picks, which need not be this one:`;
// The same where no installer exists: the page the release comes from.
export const appUpdateCommandDownloadNote = (path: string): string =>
  `Update now updates the app only. The kendex command at ${path} needs permissions this app does not have. Download the current release and replace it:`;
// A whole-settings write the engine refused because the file moved under
// it. Said wherever a change is one field and the retry is to press again.
export const SETTINGS_MOVED_MESSAGE =
  "Your settings changed in another window. Try again.";
