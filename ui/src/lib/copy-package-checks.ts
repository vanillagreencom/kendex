// Package checks: every word of the feature on a project's card, of the
// help beside it, and of the confirmation that switches it on. Kept in one
// place so the wording is reviewed as writing, and so the help and the
// confirmation cannot describe two different things — both draw the same
// sentences from here.
import type { FileRole, HarnessId, NoPreview, SetupHeld } from "@/bindings";
import { namesInWords } from "@/lib/copy";
import { harnessName } from "@/lib/labels";

export const PACKAGE_CHECKS_LABEL = "Package checks";
export const ENABLE_CHECKS_LABEL = "Enable checks";
export const PACKAGE_CHECKS_HELP_LABEL = "About package checks";
export const PACKAGE_CHECKS_HELP_TITLE = "About package checks";
export const PACKAGE_CHECKS_LIBRARY_LABEL = "Open this project's Library";

/** Why the feature exists, said before anything is asked. */
export const PACKAGE_CHECKS_PURPOSE =
  "Tell coding agents when installed packages are outdated or changed, so they can address the problem before working.";

/** The state word a card carries. The state itself, not what kendex calls
 *  the mechanism behind it. */
export const STATE_OFF = "Off";
export const STATE_ON = "On";
export const STATE_INCOMPLETE = "Setup incomplete";
export const STATE_UNKNOWN = "Unknown";

/** What each state means for a session started in this project. */
export const OFF_MEANS =
  "Agents starting a session here are not told when an installed package is outdated or changed.";
export const ON_MEANS =
  "Agents starting a session here are told when an installed package is outdated or changed.";
/** Partial coverage is this state, so the sentence says which claim is
 *  false — running everywhere — rather than saying the check does not
 *  run. The row appends [runsIn] and [notRunningIn] straight after it,
 *  and "not running yet" beside "Runs in Claude Code" is untrue of the
 *  tool where it does run. */
export const INCOMPLETE_MEANS =
  "The check is set up in this project and does not yet run in every supported tool.";
export const UNKNOWN_MEANS =
  "kendex could not read this project, so it cannot say whether the check runs here.";

/** Which of the supported tools run the check now and which do not. An
 *  installer's answer cannot say this, so it is read back from the machine
 *  and said in full: a tool left out is the difference between On and
 *  Setup incomplete. */
export const runsIn = (harnesses: readonly HarnessId[]): string =>
  `Runs in ${namesInWords(harnesses.map(harnessName))}.`;
export const notRunningIn = (harnesses: readonly HarnessId[]): string =>
  `Not running in ${namesInWords(harnesses.map(harnessName))}.`;

// ── The explanation, shared by the help and the confirmation ────────────

export const CHECKS_WHAT =
  "kendex compares the packages installed in this project with the sources they came from, and reports anything outdated or changed.";
export const CHECKS_WHEN =
  "A startup hook runs the check when a coding session starts here. A resumed or compacted session is left alone, because it already has its context.";
export const CHECKS_QUIET =
  "It is silent when everything matches. It does not update packages, repair files, commit changes or stop a session.";
export const checksHarnesses = (harnesses: readonly HarnessId[]): string =>
  `This installation registers the check in ${namesInWords(harnesses.map(harnessName))}.`;
export const CHECKS_REMOVE =
  "The check is listed in this project's Library as an installed hook. Turn it off or remove it there.";
export const HELP_INSTALLS_NOTHING = "Reading this changes nothing.";

// ── The confirmation ───────────────────────────────────────────────────

export const enableChecksTitle = (project: string): string =>
  `Enable package checks in ${project}?`;
export const FILES_DISCLOSURE_LABEL = "Files to add or change";
export const FILES_TREE_LABEL = "Files this adds or changes";
export const PLAN_PENDING = "Reading what this would write…";
export const PLAN_FAILED = "kendex could not read what this would write.";

/** What this action does to a row's file. "Unchanged" and "Later" are
 *  not writes: a file already as the setup needs it, and one the action
 *  deliberately leaves for the render it is holding back, are both named
 *  so the list never claims a change the press does not make. */
export const CHANGE_WORDS = {
  add: "Add",
  change: "Change",
  unchanged: "Unchanged",
  later: "Later",
} as const;

/** What each file in the list is for. The reader gets the role: a path
 *  under a tool's own directory says nothing about why a session-start
 *  check needs it. */
export const ROLE_WORDS: Record<FileRole, string> = {
  "check-script": "Check script",
  "startup-registration": "Startup registration",
  declaration: "Declaration",
  "install-record": "Install record",
  "repository-file": "Repository file",
};

export const roleMeans = (
  role: FileRole,
  harness: HarnessId | null,
): string => {
  switch (role) {
    case "check-script":
      // A tool gets its own copy of the script. Both rows are check
      // scripts, so the tool is what tells them apart on the list.
      return harness
        ? `The copy of the script ${harnessName(harness)} runs at session start.`
        : "The script a coding session runs at start.";
    case "startup-registration":
      return harness
        ? `What makes ${harnessName(harness)} run the script at session start.`
        : "What makes a coding tool run the script at session start.";
    case "declaration":
      return "This project's kendex file, where the check is listed like any other installed package.";
    case "install-record":
      return "kendex's record of what it installed here.";
    case "repository-file":
      return "kendex's own bookkeeping in this repository, so its records are not committed with your work.";
  }
};

/** Why a file has no content beside it. A reason rather than a blank pane:
 *  a list where some rows open and others do not is a list nobody trusts. */
export const NO_PREVIEW_WORDS: Record<NoPreview, string> = {
  "shared-file":
    "kendex adds one entry to a file that is otherwise yours. The rest of it is left exactly as it is, so there is no whole file to show before the write.",
  generated:
    "kendex writes this from what the install did, so there is nothing to show before the write.",
};

/** Other work already waiting here. A yes to the checks is not a yes to
 *  that work, so the confirmation says what enabling now does and does not
 *  do, and the sentence promises nothing about what a later apply will
 *  manage. */
export const otherChangesWaiting = (count: number): string =>
  `This project has ${count} other change${count === 1 ? "" : "s"} waiting. Enabling now writes the check script and the declaration; the registration goes in when those changes do.`;
/** Positions the planner will not write over. They hold up their own
 *  items and nothing else — the check installs nowhere near them — so this
 *  says what is unsettled without claiming the check waits on it. What the
 *  check does wait for, when it waits, is [otherChangesWaiting] beside
 *  this. */
export const CHECKS_CONFLICTS_NOTE =
  "Some positions in this project need you before kendex will write over them. Enabling the checks does not change them.";
export const CONFLICTS_LABEL = "Positions that need you";

/** Positions at the check's own destinations that nothing can settle.
 *  Unlike [CHECKS_CONFLICTS_NOTE] these do stop the registration, so this
 *  sentence says so; the two must not be run together, or one of them
 *  becomes false. */
export const CHECKS_BLOCKED_NOTE =
  "The check cannot be registered until these are settled. kendex will not write over them.";
export const BLOCKED_LABEL = "In the way of the check";

// ── After the write ────────────────────────────────────────────────────

export const checksOn = (project: string): string =>
  `Package checks are on in ${project}`;
export const checksHeld = (project: string): string =>
  `Package checks are set up in ${project} and not running yet`;
export const ENABLE_FAILED = "Couldn't enable package checks";

/** Why the setup stopped where it did. The card says which tools are
 *  covered from the read that follows the write; this is the part that
 *  read cannot recover, so it stays on the row until the setup is
 *  finished. Neither sentence promises that a later apply will manage it. */
export const heldBecause = (held: SetupHeld): string => {
  switch (held.kind) {
    case "otherChanges":
      return `The check script and the declaration are written. The registration is waiting with ${held.count} other change${held.count === 1 ? "" : "s"} this project already had.`;
    case "conflicts":
      return `The check script and the declaration are written. The registration cannot go in while these need you: ${held.detail.join(", ")}.`;
    case "notRegistered":
      return `The check script and the declaration are written. ${notRunningIn(held.harnesses)} kendex could not confirm the registration from this project's install record.`;
  }
};
