import type { MergedDriftRow } from "@/lib/drift-merge";
import type { Exits } from "@/lib/exits";
import { harnessName } from "@/lib/labels";

// The words for one state: kendex.toml asks for something, and files are
// already where it goes. Two ways forward and no way to guess which is
// wanted, so the group says only what is true of every row and each
// control carries its own consequence — a row with no Keep button then has
// nothing above it promising one.
// "Adopt" and "take over" are the engine's words for these; what a person
// needs is what happens to the files in front of them.
export const BLOCKED_HEADLINE = "Waiting on a decision from you";
export const IN_THE_WAY_BODY =
  "kendex didn't write these files, so it won't touch them until you decide.";
export const KEEP_FILES_LABEL = "Manage these files";
export const KEEP_FILES_CONSEQUENCE =
  "These files move to where kendex manages them from. The tools go on reading them.";
export const REPLACE_FILES_LABEL = "Replace them";
export const REPLACE_FILES_CONSEQUENCE =
  "kendex installs what kendex.toml asks for. The old files move to the trash.";
// Managing the files means handing them to kendex, which needs somewhere
// to put them — the project's shared tree for a project skill, the local
// source otherwise — and only some kinds have one, and only where what is
// there has the shape the item installs as: a folder where one file goes,
// or one file where a folder goes, is not something kendex can look after
// as it stands. Where it cannot, keeping them is the reader's own move, in
// the words the CLI uses.
export const MOVE_FILES_YOURSELF =
  "To keep these, move them somewhere else first.";
// Every apply is the whole place's, so the changes waiting there land in
// the same pass. Appended once where a confirmation's words are built, so
// both exits disclose it in the same sentence — either button's label only
// names the files on the row it sits on.
export const ALSO_APPLIES =
  " Anything else ready in this project is applied too.";
// The confirmation names the move, which is what the button runs, in the
// words the control that opened it used. A title asking whether to keep
// files reads as a choice about preservation, and a reader who agreed to
// that has agreed to nothing the apply does.
export const manageConfirmTitle = (name: string): string =>
  `Manage ${name} with kendex?`;
// The paths are on the row this was clicked on, so the words say what
// happens to them, not where they are. Where they land differs by arm — a
// project skill's own folder is renamed into the project's shared .agents
// tree and the tool's path becomes a link to it, while everything else is
// copied into kendex's store with the original trashed — and which arm a
// row is on is core's rule, not one the page re-derives in TS to reword a
// dialog. So the words claim only what is true either way: the files move,
// the path each tool reads goes on working, and nothing is deleted.
export const MANAGE_CONFIRM_BODY =
  "kendex moves these files to where it manages them from and leaves each tool reading them at the same path. Nothing is deleted.";
// The opener and the title carry the action, and the body says what
// happens, so the confirm only has to offer it.
export const PROCEED_LABEL = "Proceed";
// A folder several tools read through shortcuts they set up is a bigger
// move than a plain folder, so the words for it name the folder and every
// tool at it. One action, one set of words: the unmanaged list offers the
// same move and reads them from here, so one action reads as one action
// wherever it is offered. The last clause is the one honest warning, since
// shortcuts kendex cannot see will break and there is no way to list them.
export const manageSharedBody = (target: string, tools: string[]): string =>
  `${tools.join(" and ")} read this skill from ${target}. kendex moves the folder to where it manages it from and leaves each tool reading it at the same path. Nothing is deleted, but anything else pointing at the folder stops working.`;
const replaceFilesConfirmTitle = (name: string): string => `Replace ${name}?`;
// The places themselves are listed under this, one per line, so the
// sentence agrees with a list rather than trying to hold it. A summary
// spliced in here would truncate, and the confirm is the last thing read
// before the files move.
const replaceFilesConfirmBody = (count: number): string => {
  const [subject, verb, whose] =
    count > 1 ? ["These", "move", "their"] : ["This", "moves", "its"];
  return `${subject} ${verb} to the trash, and kendex installs what kendex.toml asks for in ${whose} place.`;
};
export const REPLACE_FILES_CONFIRM_LABEL = "Replace them";
export const replacedToastLabel = (name: string): string => `Installed ${name}`;

/** Which exit a row is waiting on a confirmation for. */
export type Pending = { group: MergedDriftRow; exit: "keep" | "replace" };

/**
 * What one exit asks before it runs. Only what happens to the files
 * differs, and the shared folder says the more of it: the folder moves
 * whole and shortcuts kendex cannot see break with it. It is still a move
 * and not a deletion, so it is not weighted like the replacement.
 *
 * The shared words answer for the shared installations alone. A group can
 * hold rows of more than one cause, and a summary over all of them is not
 * a folder any tool reads from.
 *
 * `places` is every position the move touches, listed by the dialog where
 * the words do not already name them. Nothing is ever collapsed to a
 * count: the row behind the dialog shows a summary whose full list lives in
 * a tooltip, and the overlay puts that out of reach at exactly the moment
 * it is needed.
 */
export function ask({ group, exit }: Pending, places: string[], exits: Exits) {
  if (exit === "replace") {
    return {
      title: replaceFilesConfirmTitle(group.name),
      body: replaceFilesConfirmBody(places.length),
      label: REPLACE_FILES_CONFIRM_LABEL,
      destructive: true,
      places,
    };
  }
  const shared = group.installations.filter(
    (row) => row.cause === "shared-link",
  );
  const folders = [...new Set(shared.map((row) => row.detail))];
  const tools = [...new Set(shared.flatMap((row) => exits.tools(row)))];
  return {
    title: manageConfirmTitle(group.name),
    body:
      folders.length > 0
        ? manageSharedBody(folders.join(" and "), tools.map(harnessName))
        : MANAGE_CONFIRM_BODY,
    label: PROCEED_LABEL,
    // The files move to where kendex manages them from and nothing is
    // deleted. A red button over a move tells the reader the opposite of
    // what the words under it say.
    destructive: false,
    // The shared words name the folder themselves; listing it again under
    // them would say one thing twice.
    places: folders.length > 0 ? [] : places,
  };
}
