// The Projects tab and the Delete dialog: what a package's places are
// called, and what acting on one of them does. Kept apart from the rest so
// the wording is reviewed as writing, the same as copy.ts.
import { relativeTime } from "@/lib/relative-time";

export const PROJECTS_TAB = "Projects";
export const PROJECTS_HEADING = "Installed in";
export const REMOVE_LABEL = "Remove";
export const UPDATE_ALL_LABEL = "Update all";
export const REMOVE_ALL_LABEL = "Remove all";
export const DELETE_LABEL = "Delete";
/** What each card's two buttons are called to a screen reader. The visible
 *  labels stay one word — the card names its place right beside them — but
 *  read on their own every card's buttons are the same word, and nothing
 *  says which installation the click reaches. Each keeps its visible label
 *  as the first word of the spoken one, so speaking the label out loud
 *  still names a button on screen. */
export const updateInLabel = (place: string): string => `Update in ${place}`;
export const removeFromLabel = (place: string): string =>
  `Remove from ${place}`;

/** When this copy was put here, or null where the record does not say —
 *  a date the app has not read is a line it does not print. */
export const installedAgo = (
  installedAt: string | null,
  nowMs: number,
): string | null => {
  if (installedAt === null) return null;
  const at = Date.parse(installedAt);
  return Number.isNaN(at) ? null : `Installed ${relativeTime(at, nowMs)}`;
};

export const PROJECTS_EMPTY = "This package is not installed anywhere.";
export const PROJECTS_LOADING = "Reading each place…";

export const deleteTitle = (name: string): string => `Delete ${name}?`;
export const DELETE_BODY =
  "kendex moves the files it manages to the trash and stops keeping this package up to date.";
export const DELETE_PLACES_LABEL = "Deleted from";
/** Marketplaces as a reader says them: "acme", "acme or beta", "acme,
 *  beta, or gamma". */
const eitherOf = (names: string[]): string => {
  if (names.length < 3) return names.join(" or ");
  return `${names.slice(0, -1).join(", ")}, or ${names[names.length - 1]}`;
};

/** Every marketplace the deleted copies came from, not one of them: a
 *  package can be installed from a different source in each place, and
 *  naming one would send the reader somewhere that never held the rest. */
export const reinstallFrom = (marketplaces: string[]): string =>
  `You can install it again from ${eitherOf(marketplaces)}.`;
export const REINSTALL_OWN =
  "This package is your own, so there is no marketplace to install it from again.";
