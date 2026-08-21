// The words for one state: kendex.toml asks for something, and files are
// already where it goes. Two ways forward and no way to guess which is
// wanted, so the group says what each one does and the row carries both.
// "Adopt" and "take over" are the engine's words for these; what a person
// needs is what happens to the files in front of them.
export const IN_THE_WAY_BODY =
  "kendex didn't write these files. Keep them and it looks after them as they are; replace them and it installs what kendex.toml asks for, moving the old files to the trash.";
export const KEEP_FILES_LABEL = "Keep these files";
export const REPLACE_FILES_LABEL = "Replace them";
// Keeping the files means handing them to kendex, which needs somewhere in
// the local source to put them — and only some kinds have one. Where they
// do not, keeping them is the reader's own move, in the words the CLI uses.
export const MOVE_FILES_YOURSELF =
  "To keep these, move them somewhere else first.";
export const replaceFilesConfirmTitle = (name: string): string =>
  `Replace ${name}?`;
export const replaceFilesConfirmBody = (
  where: string,
  alsoApplies: boolean,
): string =>
  `${where} moves to the trash, and kendex installs what kendex.toml asks for in its place.${
    // Every apply is the whole project's, so the changes listed under Apply
    // land in the same pass. Said here, because this button's label only
    // names the files.
    alsoApplies ? " Anything else ready in this project is applied too." : ""
  }`;
export const REPLACE_FILES_CONFIRM_LABEL = "Replace them";
export const replacedToastLabel = (name: string): string => `Installed ${name}`;
