// Updates page copy: the table, the edited-copy row, and the toasts that
// say what a bulk update did — kept apart from the rest so the wording is
// reviewed in one place.
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
export const installedBesideUnfinishedToast = (
  name: string,
  own: string,
  why: string,
): string =>
  `Your edited copy is now ${own}, but ${name} didn't install: ${why}. Review & apply finishes it.`;
export const OPEN_PACKAGE_LABEL = "Open package";

export const updatedWithPlaceToastLabel = (
  name: string,
  place: string,
): string => `Updated ${name} and everything else following in ${place}`;
export const updatedSomeToastLabel = (
  updated: number,
  skipped: number,
): string =>
  `Updated ${updated === 1 ? "1 package" : `${updated} packages`} — ${skipped === 1 ? "1 place needs" : `${skipped} places need`} attention on its own row`;
export const updatedCountToastLabel = (updated: number): string =>
  `Updated ${updated === 1 ? "1 package" : `${updated} packages`}`;
export const nothingToUpdateToastLabel = (skipped: number): string =>
  `Nothing to update — ${skipped === 1 ? "1 place needs" : `${skipped} places need`} attention on its own row`;

// Before the first read answers there is nothing to be up to date about,
// and a check that failed leaves the last rows on screen rather than
// blanking the page — drawn, but never presented as current.
export const UPDATES_CHECKING = "Checking for updates…";
export const UPDATES_UNCONFIRMED_TITLE =
  "These are the last versions kendex could check";
export const UPDATE_NEEDS_CHECK_NOTE =
  "Updating needs a check that succeeds first — these versions may be stale";
