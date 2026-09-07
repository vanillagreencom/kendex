// The start-of-session note: every word of the offer on a project's card
// and of each state it can be in. Kept in one place so the wording is
// reviewed as writing, beside the terminal's `drift::hook`, which installs
// the same thing.
//
// The offer lives on the card and nowhere else. A toast at registration
// vanished with the toast and named a mechanism nobody had met; the card
// is where a person can come back to it, and it says what the thing is,
// what changes on disk, and what pressing the button does.

export const SESSION_NOTE_LABEL = "Start-of-session note";

/** What it is, said before anything is asked. */
export const SESSION_NOTE_WHAT =
  "When a coding agent starts a session in this project, kendex leaves it a short note saying whether any installed file no longer matches its source. When everything matches, nothing is left.";

/** What changes on disk when the button is pressed: the script and the
 *  declaration `drift::hook::install_plan` writes, and the render that
 *  follows into each harness that runs hooks, Claude Code and Pi. */
export const SESSION_NOTE_CHANGES =
  "This writes a small script into the project, adds a hook entry to its settings for Claude Code and for Pi, and lists the note in the project's kendex file so kendex keeps it up to date like anything else it installs. You can remove it from the Library.";

export const ADD_SESSION_NOTE_LABEL = "Add the note";
export const addSessionNoteTitle = (project: string): string =>
  `Add a start-of-session note to ${project}?`;

/** The three states the card can name. Each says what agents starting
 *  here get, not what kendex calls the state. */
export const SESSION_NOTE_OFF =
  "Agents starting a session here are not told when an installed file no longer matches its source.";
export const SESSION_NOTE_ON =
  "Agents starting a session here are told when an installed file no longer matches its source.";
/** The hook is declared and not in place: the project had other changes
 *  waiting and a yes to the note is not a yes to those, or something is in
 *  the way of the registration. The one way to put them in, and to be
 *  told what is in the way, is the terminal, so the sentence names the
 *  command. */
export const SESSION_NOTE_WAITING =
  "The note is set up but not in place yet. This project has other changes waiting, and it goes in with them when you run kendex apply in that folder.";

export const sessionNoteAdded = (project: string): string =>
  `Start-of-session note added to ${project}`;
export const sessionNoteWaiting = (project: string): string =>
  `The note for ${project} is set up but not in place yet`;
export const SESSION_NOTE_FAILED = "Couldn't add the start-of-session note";
