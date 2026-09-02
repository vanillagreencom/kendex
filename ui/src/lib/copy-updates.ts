// Update copy: the Updates page's table, the edited-copy row, the toasts
// that say what a bulk update did, and every note the package page puts
// where its own Update would have been — whichever of its two reads the
// reason comes from. Kept apart from the rest so the wording is reviewed in
// one place, and one slot's strings are read side by side.
import { relativeTime } from "@/lib/relative-time";

export const NEVER_CHECKED = "Not checked for updates yet";

/** How old the standing on this page is. "Everything is up to date" is only
 *  as true as the fetch under it, and the check runs offline on load, so the
 *  page says when it last reached a source rather than letting a clean
 *  answer speak for an age nobody can see. */
export const lastCheckedLabel = (
  /** Unix seconds of the last successful fetch, as the overview reports it. */
  fetchedAt: number | null,
  nowMs: number,
): string =>
  fetchedAt === null
    ? NEVER_CHECKED
    : `Last checked ${relativeTime(fetchedAt * 1000, nowMs)}`;

export const FOLLOW_SOURCE_COLUMN = "Follow source";
export const FOLLOW_SOURCE_HELP =
  "On, this package takes the newest version when you press Update, and moves with everything else here when the place refreshes; off, it stays on this version until you choose one.";
export const heldInLabel = (held: number, total: number): string =>
  `Held in ${held} of ${total}`;
export const followSourceLabel = (name: string, place: string): string =>
  `Follow the source for ${name} in ${place}`;
export const UPDATES_NAME_COLUMN = "Package";
export const UPDATES_TYPE_COLUMN = "Type";
export const UPDATES_PLACE_COLUMN = "Where";
export const UPDATES_VERSION_COLUMN = "Version";
export const TABLE_OPTIONS_LABEL = "Table options";
export const SHOW_VERSION_LABEL = "Show version";
export const USER_LEVEL_PLACE = "User level";
export const placesLabel = (count: number): string =>
  count === 1 ? "1 place" : `${count} places`;
export const updatesSubtitle = (packages: number, places: number): string =>
  `${packages === 1 ? "1 update" : `${packages} updates`} across ${placesLabel(places)}`;
export const UPDATE_PACKAGE_EVERYWHERE_LABEL = "Update all";
export const heldBySourceNote = (source: string): string =>
  `Held by the source "${source}" as a whole — release it where that source is declared`;
export const HELD_BY_OWNER_NOTE =
  "Held by the bundle or package it came with — update or release it from there";
/** The same hold with its owner named, wherever the Library knows which
 *  package requires this one. */
export const heldByParentNote = (parent: string): string =>
  `Held by ${parent}, which requires it — update or release it from there`;
// The update read covers declared packages with a repository source. A
// package page opened on anything else has news from its own timeline and
// no standing to act on it, and saying so beats a page with no button and
// no reason on it.
export const NO_UPDATE_STANDING_NOTE =
  "The update check has not spoken for this package here";
// The package page's own two reads: the record that says held or
// following, and the timeline Update moves along. Neither is the update
// check, so this sends nobody to press Check — it carries what the read
// itself came back with, which is the whole difference between a package
// with nothing to update and one the page could not read.
export const PACKAGE_READ_FAILED = "Couldn't read this package here";
export const packageReadFailedNote = (reason: string): string =>
  `${PACKAGE_READ_FAILED} — ${reason}`;

// An edited copy is the user's work: no update touches it. The newest
// version can only land beside it, under the name it always had, with the
// edited copy renamed to one of the user's choosing.
export const EDITED_TAG_HELP =
  "You changed this package's files. Updating would overwrite them, so this copy stays as it is; Install as new package puts the newest version beside it.";
export const EDITED_CANT_UPDATE_NOTE =
  "Can't be updated — you've edited this copy";
export const INSTALL_AS_NEW_LABEL = "Install as new package";
export const installAsNewTitle = (name: string): string =>
  `Install ${name} as a new package`;
export const installAsNewBody = (name: string): string =>
  `The newest version from the source installs as ${name}. Your edited copy stays, as your own package under the name below.`;
export const OWN_COPY_NAME_LABEL = "Name for your edited copy";
export const ownCopyDefaultName = (name: string): string => `${name}-edited`;
export const installedAsNewToastLabel = (name: string, own: string): string =>
  `Installed ${name} — your edited copy is now ${own}`;
// The rename went into the manifest and the write to disk did not, so this
// says both halves rather than only the one that worked. It names no way to
// finish: the page that ran a recorded plan is gone, and pointing at a
// screen that no longer exists is worse than the reason on its own.
export const installedBesideUnfinishedToast = (
  name: string,
  own: string,
  why: string,
): string =>
  `Your edited copy is now ${own}, but ${name} didn't install: ${why}.`;
export const OPEN_PACKAGE_LABEL = "Open package";

export const updatedCountToastLabel = (updated: number): string =>
  `Updated ${updated === 1 ? "1 package" : `${updated} packages`}`;
// The tools an apply's `held_back` or `removed` list names, because that is
// where the person goes to settle it.
const toolList = (tools: string[]): string =>
  tools.length > 1
    ? `${tools.slice(0, -1).join(", ")} and ${tools[tools.length - 1]}`
    : (tools[0] ?? "");
// A rendering the plan refused to write over and left exactly as it is.
// Said without a lead, so the one line is true whether the package moved
// in another tool or nowhere at all.
export const heldBackToastLabel = (tools: string[]): string =>
  `The copy in ${toolList(tools)} was left as it is — settle it on the package page`;
// A refusal with nothing of the person's in the files does not leave the
// old copy alone: it goes to the trash and nothing is written back. Said
// plainly, because it is the one outcome that took something away, and
// sized by the packages it took: the tools dedupe, so a run that lost five
// packages in one tool would otherwise read as one copy.
export const removedNotReplacedToastLabel = (
  packages: number,
  tools: string[],
): string =>
  packages === 1
    ? `The copy in ${toolList(tools)} went to the trash and nothing replaced it`
    : `The copies of ${packages} packages in ${toolList(tools)} went to the trash and nothing replaced them`;
// A place's apply answers for every package it was asked about. One
// missing means the run cannot say what became of that package, and a
// count that quietly leaves it out would claim more than the run knows.
export const unansweredPackageError = (name: string): string =>
  `${name} was applied with its place, but the answer for it did not come back — check the package's own row`;
export const nothingToUpdateToastLabel = (skipped: number): string =>
  `Nothing to update — ${skipped === 1 ? "1 place needs" : `${skipped} places need`} attention on its own row`;
// Every apply committed and the plan wrote nothing: what the run was asked
// to move had already moved, by another window, another lane or the CLI,
// between the check and the click. A run that says nothing at all over
// that reads as a click that missed. Worded so no count is needed — one
// place's button reaches the same run as "Update all".
export const ALREADY_CURRENT_TOAST =
  "Nothing to write — everything here was already up to date";

// Before the first read answers there is nothing to be up to date about,
// and a check that failed leaves the last rows on screen rather than
// blanking the page — drawn, but never presented as current.
export const UPDATES_CHECKING = "Checking for updates…";
export const UPDATES_UNCONFIRMED_TITLE =
  "These are the last versions kendex could check";
// The Updates table's rows are the update read's own answer, so a read
// that did not land leaves the versions beside the button stale. The
// package page draws its timeline from its own read, which landed, so it
// says the first half and stops: only the standing behind Update is
// unconfirmed there, not the versions on screen.
const NEEDS_A_CHECK = "Updating needs a check that succeeds first";
export const UPDATE_NEEDS_CHECK_NOTE = `${NEEDS_A_CHECK} — these versions may be stale`;
export const UPDATE_NEEDS_CHECK_HERE = NEEDS_A_CHECK;
// A check and a write never run together: the check builds its report once,
// so a change landing while it is out would be missing from it. The rows are
// not stale and nothing needs checking first, which is why this is its own
// note rather than the one above — the only thing in the way is the work
// already running.
export const UPDATES_ONE_AT_A_TIME_NOTE =
  "A check or an update is already running — try again when it finishes";

// A place whose lock or manifest this build refuses has no standing at
// all, while every other place's rows are as good as ever. The page names
// the place rather than reporting the whole machine unchecked, and sends
// the reader to Problems, which carries the reason and the way out.
//
// "Places", not "projects": the update read folds every scope, personal
// included, so an unreadable personal lock lands here too and calling it a
// project would be a plain untruth about the one place that is not one.
export const UPDATES_UNREADABLE_TITLE = "Some places couldn't be read";
export const unreadablePlacesLabel = (names: string[]): string =>
  `No update standing for ${names.join(", ")}.`;
/** One place's line where there is room for the reason the read gave —
 * the note on the Updates page. The badge tooltip and Home's row have a
 * line each and name the places only. Which kind of failure it was is
 * typed on the audit's card, which Problems draws; this is the words the
 * read itself came back with. */
export const unreadablePlaceLine = (place: string, reason: string): string =>
  `${place} — ${reason}`;
