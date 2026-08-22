// What the app says when it finds files you edited by hand: the state, the
// exits, and the two refusals that protect the record of what you kept.

// Fork: what happens when the app finds files you edited by hand.
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
// A fork has already been kept as your own, so that half of the choice is
// spent. What is left is the copy you kept: the app can put it back.
export const FORKED_NOTICE_DETAIL =
  "Updates are paused so your edits stay. Discard them to go back to the copy you kept.";
// The copy a discard would put back cannot be read — emptied, replaced, or
// past what a catalog tree may be. The button is not offered, so the line
// must not offer it either: naming an exit that refuses is worse than
// naming none. `kendex check` says the same of this row.
export const FORKED_UNREADABLE_DETAIL =
  "Updates are paused so your edits stay. The copy you kept can no longer be read, so there is nothing to put back — the files on disk are what you have.";
export const FORKED_DISCARD_CONFIRM_BODY =
  "The copy you kept replaces your edits to this package, and your changes are gone.";
export const DISCARD_EDITS_CONFIRM_TITLE = "Discard your edits?";
export const DISCARD_EDITS_CONFIRM_BODY =
  "The catalog's version replaces your edits to this package, and your changes are gone. Keep them as your own copy instead if you're unsure.";
export const DISCARD_EDITS_CONFIRM_LABEL = "Discard edits";
export const FORK_ERROR_TITLE = "Couldn't keep the edits";

// Keeping a fork and discarding edits both rewrite the same kendex.toml the
// Customize tab is editing. Saving afterwards would write the older copy in
// hand back over it, and the fork record lives nowhere else.
export const UNSAVED_FIRST_TITLE = "Save your customization first";
export const UNSAVED_FIRST_BODY =
  "This rewrites the same settings file you have unsaved changes in, and saving those afterwards would put the old contents back.";
// The unsaved copy may be parked behind another place: moving between
// places keeps typing rather than dropping it, so the steps have to name
// where to go back to instead of pointing at the tab on screen.
export const unsavedFirstSteps = (place: string | null): string[] => [
  place === null
    ? "Open the Customize tab and save or discard your changes"
    : `Open ${place} and save or discard your changes on its Customize tab`,
  "Then try this again",
];

// Keeping a fork, discarding edits, switching version, installing, and
// settling a finding all rewrite the same kendex.toml the Customize tab is
// holding a copy of. Saving that copy afterwards would put the older file
// back, and a fork's own entry lives nowhere else — so the note names what
// happened rather than one of the ways it can happen.
export const OUTDATED_DRAFT_TITLE = "These settings changed while you typed";
export const OUTDATED_DRAFT_BODY =
  "Something else rewrote this place's settings, so what is on screen is older than the file. Saving it would undo that change.";
export const RELOAD_SETTINGS_LABEL = "Reload settings";
