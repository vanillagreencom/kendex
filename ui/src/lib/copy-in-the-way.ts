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
// the local source to put them — and only some kinds have one, and only
// where what is there has the shape the item installs as: a folder where
// one file goes, or one file where a folder goes, is not something kendex
// can look after as it stands. Where it cannot, keeping them is the
// reader's own move, in the words the CLI uses.
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
// Keeping a folder several tools read through shortcuts they set up is a
// bigger move than keeping a plain folder, so the words for it say what
// happens to the folder itself. One action, one set of words: the Library
// offers the same move and reads them from here, because a dialog that
// renames the button that opened it leaves the reader unsure what they
// agreed to. The last sentence is the one honest warning — shortcuts
// kendex cannot see will break, and there is no way to list them.
export const keepSharedBody = (target: string, tools: string[]): string =>
  `${tools.join(" and ")} read this skill from ${target}. kendex moves the folder's content into its own keeping — the folder goes to the trash, where you can get it back — and points them at kendex's copy, so they stay in sync. Anything else pointing at the old folder stops working.`;
// The Review page adds the whole-project note, so both exits on a row
// disclose the same apply.
export const keepSharedConfirmBody = (
  target: string,
  tools: string[],
  alsoApplies: boolean,
): string =>
  `${keepSharedBody(target, tools)}${alsoApplies ? ALSO_APPLIES : ""}`;
export const replaceFilesConfirmTitle = (name: string): string =>
  `Replace ${name}?`;
// One or two places read as themselves. Past that the summary is "<first>
// +2 more", which spliced into a sentence reads as a fragment, so the
// count carries it instead — every path is still on the row above, in full.
export const replaceFilesConfirmBody = (
  where: string,
  count: number,
  alsoApplies: boolean,
): string => {
  const also = alsoApplies ? ALSO_APPLIES : "";
  if (count > 2) {
    return `Files at ${count} places move to the trash, and kendex installs what kendex.toml asks for instead.${also}`;
  }
  const [verb, whose] = count > 1 ? ["move", "their"] : ["moves", "its"];
  return `${where} ${verb} to the trash, and kendex installs what kendex.toml asks for in ${whose} place.${also}`;
};
export const REPLACE_FILES_CONFIRM_LABEL = "Replace them";
export const replacedToastLabel = (name: string): string => `Installed ${name}`;
