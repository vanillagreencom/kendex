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
export const FEWER_ITEMS_LABEL = "Show less";
export const morePlacesLabel = (count: number): string =>
  `+${count} more place${count === 1 ? "" : "s"}`;
export const AFFECTS_LABEL = "Affects";

// Review & apply page copy: what "managing" an item buys you, said once
// here so "Start managing" doesn't need to explain itself on every row.
export const ALL_IN_SYNC_TITLE = "Everything is in sync";
export const ALL_IN_SYNC_BODY =
  "Changes from Customize or your catalogs show up here.";
// Says what you get, not what the app calls the state you'd be leaving.
export const UNMANAGED_SECTION_EXPLAINER =
  "Hand one over and kendex keeps it updated, checked and copied to every harness.";
export const START_MANAGING_LABEL = "Start managing";
// The apply flow, said as what will happen rather than as what the engine
// calls it. "Orphan" is a word for whoever wrote the planner; the person
// reading this wants to know something will be deleted and what it is.
export const APPLY_DIALOG_TITLE = "Apply these changes?";
export const APPLY_DIALOG_BODY =
  "kendex will update the files it manages. Nothing else on your machine is touched.";
export const APPLY_CONFIRM_LABEL = "Apply changes";
export const APPLY_BUTTON_LABEL = "Apply changes…";
export const NOTHING_TO_DO_HERE = "Nothing to do here";
// Every attention row leads to the same page, so they all say so the same
// way. Four different verbs for one destination read as four destinations.
export const REVIEW_ACTION_LABEL = "Review & apply";

// A project's one-line summary, so a closed panel still says what is inside
// it. Written as counted nouns rather than jargon: "2 changes ready" beats
// "2 drift rows", and a person can decide whether to open it from this line
// alone.
export function scopeSummaryLabel(counts: {
  changes: number;
  conflicts: number;
  blocked: number;
  open: number;
  unmanaged: number;
}): string | null {
  const parts: string[] = [];
  if (counts.blocked > 0) {
    parts.push(`${counts.blocked} problem${counts.blocked === 1 ? "" : "s"}`);
  }
  // A conflict is not "to apply" — no button clears one — but a card that
  // leaves it out reads as nothing to do while opening onto a section that
  // says otherwise.
  if (counts.conflicts > 0) parts.push(`${counts.conflicts} waiting on you`);
  if (counts.changes > 0) parts.push(`${counts.changes} to apply`);
  if (counts.open > 0) {
    parts.push(`${counts.open} finding${counts.open === 1 ? "" : "s"}`);
  }
  if (counts.unmanaged > 0) parts.push(`${counts.unmanaged} unmanaged`);
  return parts.length > 0 ? parts.join(" · ") : null;
}
export const UNMANAGED_PAGE_SUBTITLE =
  "On your machine, but kendex didn't put them there";
export const ALL_MANAGED_TITLE = "Everything is managed";
export const ALL_MANAGED_BODY =
  "kendex looks after every skill, agent and hook it can see.";
export const SEE_IN_LIBRARY_LABEL = "See them in the Library";
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
export const removeLeftBehindLabel = (count: number): string =>
  count === 1
    ? "Also delete 1 item nothing asks for any more"
    : `Also delete ${count} items nothing asks for any more`;
export const startManagingAllLabel = (count: number): string =>
  `Start managing all ${count}`;
export const showAllItemsLabel = (count: number): string => `Show all ${count}`;
export const HIDE_ITEMS_LABEL = "Hide";
export const adoptedToastLabel = (name: string): string =>
  `Now managing ${name}`;

export const RECENT_ACTIVITY_EMPTY = "Nothing on this machine has changed yet.";

export const TAGS_ROW_LABEL = "For";

export const ADD_PROJECT_HELP =
  "Point kendex at a repository and it keeps that project's harnesses in sync too.";
export const SCAN_FOLDER_HELP =
  "Look inside a folder for repositories, then add the ones you want.";
export const NO_PROJECTS_FOUND = "Nothing that looks like a project in there.";

// "Add from a catalog". A catalog is a git repo of shareable skills and
// agents; a bundle is a named set inside one. Both are said in terms of what
// they get you rather than what they are.
export const BUNDLES_HELP = "Ready-made sets — install everything in one go.";
export const CATALOGS_HELP =
  "Where your installable skills and agents come from.";
export const ADD_CATALOG_LABEL = "Add a catalog";
export const CHECK_UPDATES_LABEL = "Check for updates";
export const NO_CATALOGS_TITLE = "Nothing to install from yet";
export const NO_CATALOGS_YET =
  "A catalog is a git repository of skills and agents. Add one and everything it offers becomes installable here.";

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

// The status footer's left side: what the last scan is telling you.
export const SCANNING_LABEL = "Scanning…";
export const scanStatusLabel = (scannedAgo: string | null): string =>
  scannedAgo ? `Up to date · scanned ${scannedAgo}` : "Up to date";

// The status footer's right side: quiet counts that link to Review & apply.
export const pendingChangesLabel = (count: number): string =>
  count === 1 ? "1 change ready" : `${count} changes ready`;
export const decisionsFooterLabel = (count: number): string =>
  count === 1
    ? "1 thing needs your decision"
    : `${count} things need your decision`;

// Package page: files, versions, and the diff between them.
export const PACKAGE_FILES_TITLE = "Files";
export const PACKAGE_VERSION_TITLE = "Version";
export const README_TAG = "readme";
export const SHOWN_BY_DEFAULT_NOTE = "Shown when the package opens";
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
// A comparison needs the version this place was installed from. Without it
// there is nothing to put beside the edit, and a button that does nothing
// and says nothing is worse than one that explains itself.
// Where a package came from is derived from one read. A failure that says
// nothing renders as a From row that is simply absent, which reads as "it
// came from nowhere" rather than "kendex could not tell".
export const ORIGIN_UNREAD = "Couldn't be read";

// A refresh that fails keeps the origin already on screen rather than
// blanking the row, so there is still something to draw. Drawn plainly it
// would read as confirmed, which is the one thing it is not.
export const ORIGIN_UNCONFIRMED = "last known";
export const originUnconfirmedTitle = (why: string): string =>
  `kendex could not check where this came from — showing the last answer it had. ${why}`;

// Nav state outlives a scan: a mark clicked before a package was removed
// from that project opens a page with nothing to say. Going back can land
// on the row that was clicked, so leaving says why.
export const packageGoneHere = (place: string): string =>
  `That package is no longer installed in ${place}.`;

export const NO_COMPARISON_TITLE = "Nothing to compare against";
export const NO_COMPARISON_BODY =
  "kendex could not read the version this package was installed from, so there is no other side to show. Refreshing this place may bring it back.";

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

// A read the app starts on its own still has to be able to fail out loud.
// Dropped, its rejection leaves whatever it feeds looking like an answer:
// a Library with nothing marked, chips still saying "being checked".
export const backgroundReadFailed = (detail: string): string =>
  `kendex couldn't finish reading your setup: ${detail}`;
export const updatedToastLabel = (name: string): string => `Updated ${name}`;
export const UPDATED_ALL_TOAST = "Everything is up to date";

export const forkedToastLabel = (name: string): string =>
  `${name} is yours now — updates are paused`;
export const forkedAttentionTitle = (count: number): string =>
  count === 1
    ? "You've edited an installed package"
    : `You've edited ${count} installed packages`;
export const FORKED_ATTENTION_DETAIL =
  "Your changes are safe — nothing will overwrite them. Decide whether to keep each as your own copy.";

export const FOLLOW_SOURCE_TOAST = "Now following its source";
