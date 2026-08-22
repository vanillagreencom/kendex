// Updates page copy: the table, the per-place decisions, and the toasts
// that say what a bulk update did — kept apart from the rest so the wording
// is reviewed in one place.
export const FOLLOW_SOURCE_COLUMN = "Follow source";
export const FOLLOW_SOURCE_HELP =
  "Following packages come current when their place refreshes or you press Update, which also brings that place's other followers current. Held ones wait until you choose.";
export const heldInLabel = (held: number, total: number): string =>
  `Held in ${held} of ${total}`;
export const followSourceLabel = (name: string, place: string): string =>
  `Follow the source for ${name} in ${place}`;
export const UPDATES_NAME_COLUMN = "Package";
export const UPDATES_TYPE_COLUMN = "Type";
export const UPDATES_PLACE_COLUMN = "Where";
export const UPDATES_VERSION_COLUMN = "Version";
export const USER_LEVEL_PLACE = "User level";
export const placesLabel = (count: number): string =>
  count === 1 ? "1 place" : `${count} places`;
export const updatesSubtitle = (packages: number, places: number): string =>
  `${packages === 1 ? "1 update" : `${packages} updates`} across ${placesLabel(places)}`;
export const UPDATE_PACKAGE_EVERYWHERE_LABEL = "Update all";
export const CUSTOMIZED_HERE_LABEL = "Customized here";
export const USE_NEW_VERSION_LABEL = "Use new version…";
export const UNFORKABLE_EDIT_NOTE =
  "Edited in a tool whose copy can't be kept as your own";
export const heldBySourceNote = (source: string): string =>
  `Held by the source "${source}" as a whole — release it where that source is declared`;
export const HELD_BY_OWNER_NOTE =
  "Held by the bundle or package it came with — update or release it from there";
export const DERIVED_EDIT_NOTE =
  "Comes with a bundle or another package — settle it on the package page";
export const MULTI_TOOL_EDIT_NOTE =
  "Edited in several tools — settle it on the package page";
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

// A check that failed leaves the last rows on screen rather than blanking
// the page. They are not current, and nothing may be applied off them.
// Before the first read answers there is nothing to be up to date about.
// Saying so anyway is the same claim as a place marked untouched when
// nobody had looked, which is the fault these pages exist to stop making.
export const UPDATES_CHECKING = "Checking for updates…";

export const UPDATES_UNCONFIRMED_TITLE =
  "These are the last versions kendex could check";
export const UPDATES_UNCONFIRMED_BODY =
  "The check didn't finish, so nothing here can be updated until one does.";
