// Repository-effects copy: the block a person reads before a package
// changes how their repository works, and the two answers. Kept in one
// place so the wording is reviewed beside the terminal's, which says the
// same things in the same order.

export const repoEffectsTitle = (name: string) =>
  `${name} changes how this repository works`;

/** Under the title: the files are in, the effect is what waits. */
export const REPO_EFFECTS_STANDING =
  "The package's own files are installed. This is the part removing it does not undo, and it waits for your yes.";

export const REPO_EFFECTS_WRITES_LABEL = "Writes";
export const REPO_EFFECTS_SHARED_NOTE =
  "That directory belongs to the repository, not this checkout: every work tree shares these files.";
export const REPO_EFFECTS_COMPANIONS_LABEL = "Companion packages";
export const COMPANION_INSTALLED = "installed";
export const COMPANION_NOT_INSTALLED = "not installed";
export const REPO_EFFECTS_UNDO_LABEL = "To undo";
export const REPO_EFFECTS_NO_REMOVAL =
  "The package declares no removal instructions.";

export const REPO_EFFECTS_APPLY_LABEL = "Apply repository changes";
export const REPO_EFFECTS_DECLINE_LABEL = "Not now";
/** A declaration with no installer: nothing for kendex to run. */
export const REPO_EFFECTS_NOTHING_TO_RUN =
  "kendex has nothing to run for this. Arm it yourself when you are ready.";
export const REPO_EFFECTS_DONE_LABEL = "Done";

export const repoEffectsAppliedToast = (name: string) =>
  `Applied ${name}'s repository changes`;
export const repoEffectsDeclinedToast = (name: string) =>
  `${name} is installed; its repository changes were not applied`;
export const repoEffectsWithheldToast = (name: string, reason: string) =>
  `${name} is installed but its repository changes were not disclosed: ${reason}`;
