// The words for pending project changes: the line on a project's card, the
// review a person opens from it, and the two ways out of a change they do
// not want.
//
// One place, because the same facts are said on three surfaces — a card, a
// project's own view, and the review page — and three spellings of "kendex
// wrote files here that are not committed" would read as three different
// states.

const plural = (n: number) => (n === 1 ? "" : "s");

/** The card's quiet line. It says what is waiting and what the click opens,
 *  so the number is never something nobody can act on. */
export const changesToReview = (count: number) =>
  `${count} change${plural(count)} to review`;
export const REVIEW_CHANGES_LABEL = "Review changes";

/** The read that says what is pending would not run. Not zero changes —
 *  nothing is known about this project — so the line says so and offers the
 *  read again. */
export const COULD_NOT_CHECK = "Could not check for changes";

export const projectChangesTitle = (project: string) => `Changes in ${project}`;
export const PROJECT_CHANGES_STANDING =
  "kendex wrote these files in this project and they are not committed. Nothing here is committed until you commit it.";
export const WHERE_SECTION = "Where";
export const CHANGED_FILES_SECTION = "Changed files";
export const BRANCH_LABEL = "Branch";
export const FOLDER_LABEL = "Folder";
/** No branch, no operation: a row with nothing to say still keeps its
 *  shape, so the pair below it does not shift up the page. */
export const NOT_APPLICABLE = "—";
export const NO_BRANCH_VALUE = "None — this checkout is on no branch";
export const inProgressValue = (operation: string) =>
  `${operation} is in progress`;

/** Why the commit is not on offer from the review, said where the button
 *  would be. The changes stay on screen either way. */
export const NO_BRANCH_HELD =
  "A commit needs a branch. Check out a branch, then check again.";
export const inProgressHeld = (operation: string) =>
  `Finish or stop ${operation} first, then check again.`;
export const UNREADABLE_HELD =
  "kendex could not read this project, so it cannot say what a commit would carry.";

export const NOTHING_PENDING =
  "kendex has written nothing here that is not committed.";
export const COMMIT_CHANGES_LABEL = "Commit…";
export const REVERT_LABEL = "Put files back…";
export const CHANGES_UNAVAILABLE_TITLE = "Couldn't open the commit";
export const CHANGES_GONE_NOTE =
  "These files have changed back since kendex looked. There is nothing left to commit.";

/** The two ways out of an edit, named apart. A commit records what is on
 *  disk; it settles nothing about where the file came from. */
export const PACKAGE_EDITS_LABEL = "Changed a package's files yourself?";
export const PACKAGE_EDITS_NOTE =
  "Committing records the file as it stands now. It does not make the package yours: kendex still renders this path, and the next update writes over it.";
export const PACKAGE_EDITS_ROUTES =
  "For a setting you want to keep, use Customize, or write it in the project's kendex.toml. For a file you edited by hand, a package's own page offers the two supported ways out where its rendering allows them: keep your copy as your own package, or discard the edits and render it again from its source.";
export const EDITED_PACKAGES_LABEL = "Show edited packages here";

/** Putting files back. The target is stated exactly, because the other way
 *  out — rendering a package again from its source and your customization —
 *  restores something else, and calling one the other would leave a person
 *  expecting the wrong result. */
export const REVERT_TITLE = "Put these files back?";
export const REVERT_STANDING =
  "kendex writes the version in your last commit back over these files. Your staged changes, the shared configuration files and every other file in this project stay exactly as they are.";
export const REVERT_NOT_REGENERATE =
  "This restores what git holds. It does not render a package again from its source, and it does not settle an edit kendex is holding a package back over.";
export const REVERT_CONFIRM_LABEL = "Put them back";
export const REVERT_READING = "Working out what this would do…";
export const REVERT_NOTHING = "There is nothing left to put back.";
export const REVERT_FAILED_TITLE = "Couldn't put the files back";
export const RESTORED_LABEL = "Back to the last commit";
export const REMOVED_LABEL = "Moved to the trash";
export const REMOVED_NOTE =
  "Your last commit holds no version of these, so putting them back means taking them away. kendex never deletes: they move to the trash.";
export const ADDED_LABEL = "Taken in as well";
export const ADDED_NOTE =
  "This records what kendex renders here. Left out, the next write into this project would put the files you just restored straight back. Its own uncommitted change goes back with it.";
export const DROPPED_LABEL = "Left out";
export const DROPPED_NOTE =
  "These have changed back since kendex looked; there is nothing to put back.";
/** The run stopped part-way. What did move is stated before git's words:
 *  being told it failed while the files moved anyway is the one reading this
 *  must not leave. */
export const PARTIAL_NOTE =
  "kendex stopped part-way. These files were already put back before it stopped:";
export const PARTIAL_REST_NOTE =
  "Everything else is where it was. Read what git said below, then check again.";
export const revertedToast = (restored: number, removed: number) => {
  if (removed === 0) return `Put ${restored} file${plural(restored)} back`;
  if (restored === 0)
    return `Moved ${removed} file${plural(removed)} to the trash`;
  return `Put ${restored} file${plural(restored)} back and moved ${removed} to the trash`;
};

/** Which files the review is about to put back. The whole pending set, or
 *  the one file open in the viewer. */
export const REVERT_ALL_LABEL = "All of them";
export const revertOneLabel = (path: string) => `Only ${path}`;
