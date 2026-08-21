// The words for one state: kendex.toml asks for something, and files are
// already where it goes. Two ways forward and no way to guess which is
// wanted, so the group says only what is true of every row and each
// control carries its own consequence — a row with no Keep button then has
// nothing above it promising one.
// "Adopt" and "take over" are the engine's words for these; what a person
// needs is what happens to the files in front of them.
export const IN_THE_WAY_BODY =
  "kendex didn't write these files, so it won't touch them until you decide.";
export const KEEP_FILES_LABEL = "Keep these files";
export const KEEP_FILES_CONSEQUENCE = "kendex looks after them as they are.";
export const REPLACE_FILES_LABEL = "Replace them";
export const REPLACE_FILES_CONSEQUENCE =
  "kendex installs what kendex.toml asks for. The old files move to the trash.";
// Keeping the files means handing them to kendex, which needs somewhere in
// the local source to put them — and only some kinds have one. Where they
// do not, keeping them is the reader's own move, in the words the CLI uses.
export const MOVE_FILES_YOURSELF =
  "To keep these, move them somewhere else first.";
// Every apply is the whole project's, so the changes listed under Apply
// land in the same pass. Said on both confirms, because either button's
// label only names the files on the row it sits on.
const ALSO_APPLIES = " Anything else ready in this project is applied too.";
export const keepFilesConfirmTitle = (name: string): string =>
  `Keep ${name}'s files?`;
// The paths are on the row this was clicked on, so the question is what
// happens to them, not where they are.
export const keepFilesConfirmBody = (alsoApplies: boolean): string =>
  `kendex starts looking after these files as they are, and stops asking about them.${
    alsoApplies ? ALSO_APPLIES : ""
  }`;
export const KEEP_FILES_CONFIRM_LABEL = "Keep them";
export const replaceFilesConfirmTitle = (name: string): string =>
  `Replace ${name}?`;
export const replaceFilesConfirmBody = (
  where: string,
  alsoApplies: boolean,
): string =>
  `${where} moves to the trash, and kendex installs what kendex.toml asks for in its place.${
    alsoApplies ? ALSO_APPLIES : ""
  }`;
export const REPLACE_FILES_CONFIRM_LABEL = "Replace them";
export const replacedToastLabel = (name: string): string => `Installed ${name}`;
