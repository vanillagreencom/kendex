// The one model the app follows, and the words every surface says it in.
// A person has places: their personal setup, and each project they add.
// Packages are installed into a place. A package names the marketplace it
// came from and the places it is in, and it is removed from a place in one
// step. A marketplace is where packages come from — what a place does with
// one is settled in that place, never as a control beside the marketplace.
//
// Every surface stating part of this reads its words here, so two screens
// cannot describe the app two ways.

/** The Projects page's subtitle: what the places listed on it are for. */
export const PLACES_SUBTITLE =
  "Where kendex installs packages: your personal setup, and every project you add.";

/** The marketplace page's list of the places that install from it. The list
 *  opens a place and carries no control over one, because what a place does
 *  with a marketplace is settled in that place. */
export const MARKETPLACE_PLACES_HELP =
  "These places install packages from this marketplace. Open a place to see its packages. To change how a place uses this marketplace, open that place's card on Projects.";

/** A marketplace switched off in one place: nothing installed there from it
 *  runs, and nothing was deleted. Said wherever a place and a marketplace
 *  meet, so the same state never reads as two different ones. */
export const SWITCHED_OFF_HERE = "Switched off here";

/** The place card's way into the marketplaces that place installs from. */
export const PLACE_MARKETPLACES_LABEL = "Marketplaces…";

export const placeMarketplacesTitle = (place: string): string =>
  `Marketplaces in ${place}`;
export const placeMarketplacesHelp = (place: string): string =>
  `${place} installs packages from these marketplaces.`;
export const placeMarketplacesEmpty = (place: string): string =>
  `${place} installs from no marketplaces yet. Subscribe to one on the Marketplaces page.`;
/** Nothing reads a place's marketplaces until this dialog asks, so the two
 *  states before an answer have to be told apart from an empty one: only a
 *  read that landed may say a place installs from nothing. */
export const placeMarketplacesReading = (place: string): string =>
  `Reading ${place}'s marketplaces…`;
export const placeMarketplacesUnchecked = (place: string): string =>
  `kendex couldn't check which marketplaces ${place} installs from.`;
export const placeMarketplacesUnconfirmed = (place: string): string =>
  `These are the last marketplaces kendex could check for ${place}.`;

export const turnOffLabel = (source: string): string =>
  `Switch off ${source} here…`;
export const turnOnLabel = (source: string): string =>
  `Switch ${source} on again here`;
export const stopUsingLabel = (source: string): string =>
  `Unsubscribe from ${source} here…`;

export const turnOffTitle = (source: string, place: string): string =>
  `Switch off ${source} in ${place}?`;
/** What turning it off costs, before the click rather than after it: the
 *  installs stop, nothing is deleted, and kendex writes files to do it. */
export const turnOffBody = (source: string, place: string): string =>
  `Every package installed in ${place} from ${source} switches off. kendex deletes nothing, and switching ${source} on again restores them. kendex rewrites the files it manages in ${place}.`;
export const TURN_OFF_CONFIRM = "Switch off";
