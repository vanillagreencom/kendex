// Commit-offer copy: what the window asks after kendex writes into a git
// project, and every word of every state it can reach. Kept in one place so
// the wording is reviewed beside the terminal's `commit_offer/block.rs`,
// which says the same things in the same order.
//
// Every value in here is of the moment. The counts, the project's folder
// name, the remote, the branches, the commit and the pull request number
// are arguments, the way `repoEffectsTitle` takes a package name.

import type { Refused, Why } from "@/bindings";

const plural = (n: number) => (n === 1 ? "" : "s");

export const commitOfferTitle = (files: number, project: string) =>
  `kendex changed ${files} file${plural(files)} in ${project}`;

export const COMMIT_OFFER_STANDING =
  "These are the files kendex writes in this repository. Nothing is committed yet.";

export const FILES_LABEL = "Files";
export const SHARED_LABEL = "Shared files";
export const SHARED_NOTE =
  "kendex writes one key in each of these. Committing them would commit your own changes to them too, so kendex leaves them to you.";
export const OTHER_LABEL = "Other changes";
export const otherNote = (others: number) =>
  `${others} other file${plural(others)} in this repository changed. kendex does not commit these.`;

export const WHAT_TO_DO_LABEL = "What to do";
export const MESSAGE_LABEL = "Message";

export const COMMIT_SEGMENT = "Commit";
export const PUSH_SEGMENT = "Commit and push";
export const PR_SEGMENT = "Pull request";

export const COMMIT_STAYS = "The commit stays in this checkout.";
export const pushesTo = (remote: string, branch: string) =>
  `Pushes to ${remote}/${branch}.`;
export const addsToPullRequest = (number: number) =>
  `Adds a commit to pull request #${number}.`;
export const prMoves = (newBranch: string, from: string) =>
  `Commits on ${newBranch} and opens a pull request. This checkout moves to that branch. ${from} stays where it is.`;

export const LEAVE_LABEL = "Leave as diffs";
export const LEAVE_IT_HERE_LABEL = "Leave it here";
export const COMMIT_LABEL = "Commit";
export const PUSH_LABEL = "Commit and push";
export const PR_LABEL = "Open pull request";
export const COMMIT_AGAIN_LABEL = "Commit again";
export const OPEN_PR_LABEL = "Open a pull request";
export const DONE_LABEL = "Done";

export const COMMITTING_LABEL = "Committing…";
export const PUSHING_LABEL = "Pushing…";
export const OPENING_LABEL = "Opening the pull request…";

export const PUSH_ROW_LABEL = "Push";
export const PR_ROW_LABEL = "Pull request";
export const COMMIT_ROW_LABEL = "Commit";
export const BRANCH_ROW_LABEL = "Branch";
export const putBackRowLabel = (from: string) => `To put ${from} back`;

/** Why a choice is not on offer. A refusal `gh` itself worded travels as
 *  gh's own first line: kendex does not decide what it means. */
export function unavailableReason(why: Why): string {
  switch (why.kind) {
    case "noRemote":
      return "This repository has no remote.";
    case "remoteNotDecidable":
      return "This branch tracks no remote and the repository has more than one.";
    case "ghMissing":
      return "gh is not installed.";
    case "ghSaid":
      return why.line;
  }
}

/** The two sides of what a file the offer covers is compared against, in
 *  the changes panel's own bar. */
export const LAST_COMMIT_SIDE = "the last commit";
export const WORKING_TREE_SIDE = "this project now";
export const CHANGES_READ_FAILED_TITLE = "Couldn't show what changed";
/** git records a file's permissions beside its contents, and a commit
 *  carries that record. A comparison drawn as empty would tell the person
 *  nothing changed in a file the commit does change. */
export const SAME_CONTENT_NOTE =
  "Nothing inside this file changed. The commit carries a change git keeps beside the contents — the file's permissions, such as whether it can be run.";

export const GIT_SAID_LABEL = "What git said";
export const GH_SAID_LABEL = "What gh said";

export const saidLabel = (refused: Refused) =>
  refused.gh ? GH_SAID_LABEL : GIT_SAID_LABEL;

/** A step that ran out of time. Its outcome is not known here, so it is
 *  never reported as done. */
export const didNotFinish = (seconds: number) =>
  `kendex stopped waiting after ${seconds} second${plural(seconds)}. Whether it finished is not known here.`;

const capitalised = (step: string) =>
  step.charAt(0).toUpperCase() + step.slice(1);

/** The title of the state a refused commit reaches. The staging is its own
 *  step and its own title: it happens before any commit, so the words the
 *  commit's title carries would name something that never ran. */
export function commitRefusedTitle(refused: Refused): string {
  if (refused.timedOut) return `${capitalised(refused.step)} did not finish`;
  switch (refused.step) {
    case "the staging":
      return "The files could not be staged";
    // The set is re-derived before the commit, and that read can fail
    // like the one the offer was built from.
    case "the check":
      return "The files could not be checked";
    default:
      return "The commit was refused";
  }
}

export const BRANCH_REFUSED_TITLE = "The branch could not be made";
export const BRANCH_REFUSED_LINE =
  "Nothing was committed and this checkout has not moved.";
export const backOn = (from: string, branch: string) =>
  `This checkout is back on ${from} and ${branch} is gone.`;

/** The commit refused on the `pr` route and the switch back, or the
 *  removal of the empty branch, refused too: the checkout is still on the
 *  new branch, and kendex stops there. Both programs' words are shown,
 *  this line between them. */
export const NOT_PUT_BACK_LINE = "The checkout could not be put back.";
/** The same state where no commit was refused first: the set emptied on
 *  the `pr` route and the switch back refused. */
export const NOT_PUT_BACK_TITLE = "The checkout could not be put back";

/** kendex staged paths it could not then unstage, against the rule that
 *  the index ends as it began. */
export const stillStaged = (count: number) =>
  `kendex staged ${count} file${plural(count)} it could not unstage. They are still staged.`;

export const PUSH_REFUSED_TITLE = "Committed, not pushed";
export const pushRefusedTitle = (refused: Refused) =>
  refused.timedOut ? "The push did not finish" : PUSH_REFUSED_TITLE;
export const commitIsOn = (branch: string) =>
  `The commit is on ${branch} in this checkout. kendex did not undo it.`;
export const stillCarries = (from: string) =>
  `${from} in this checkout still carries the commit.`;
export const resetCommand = (before: string) => `git reset --mixed ${before}`;

export const PR_REFUSED_TITLE = "Committed and pushed, no pull request";
export const pullRequestRefusedTitle = (refused: Refused) =>
  refused.timedOut ? "The pull request did not finish" : PR_REFUSED_TITLE;
export const branchIsOn = (remote: string) =>
  `The branch is on ${remote}. Open the pull request yourself.`;

export const PR_OPEN_TITLE = "Pull request open";
export const commitOn = (sha: string, branch: string) => `${sha} on ${branch}`;
export const remoteBranch = (remote: string, branch: string) =>
  `${remote}/${branch}`;
export const nowOn = (branch: string) => `This checkout is now on ${branch}.`;

export const committedToast = (files: number) =>
  `Committed ${files} file${plural(files)}`;
export const pushedToast = (files: number) =>
  `Committed and pushed ${files} file${plural(files)}`;
export const NOTHING_TO_COMMIT_TOAST = "Nothing to commit";

/** The project card's badge, for the two states where kendex owns changed
 *  files and cannot offer, and for a repository it could not read. */
export const uncommittedBadge = (count: number) => `${count} uncommitted`;
export const NOT_CHECKED_BADGE = "Not checked";

export const uncommittedNoBranch = (count: number) =>
  `${count} file${plural(count)} kendex wrote ${count === 1 ? "is" : "are"} not committed. This checkout is on no branch.`;
export const uncommittedInProgress = (count: number, operation: string) =>
  `${count} file${plural(count)} kendex wrote ${count === 1 ? "is" : "are"} not committed. ${capitalised(operation)} is in progress.`;
export const notChecked = (said: string[]) =>
  `kendex could not check the files it wrote here.${said.length > 0 ? ` git said: ${said[0]}` : ""}`;

export const GIT_PROJECTS_SECTION = "Git projects";
export const COMMIT_OFFER_SETTING_LABEL = "Offer to commit kendex's changes";
export const COMMIT_OFFER_SETTING_DESCRIPTION =
  "In a git project, ask what to do with the files kendex wrote.";

/** The scan behind a write could not say what a project holds. The same
 *  words the store's other transport failures use, said where this one is
 *  reported — after the questions ahead of it, so it never lands over an
 *  install still saying what it did. */
export const SCAN_FAILED_TITLE = "Couldn't reach kendex";
export const SCAN_FAILED_STEPS = [
  "Try again",
  "If it keeps happening, restart kendex",
];
