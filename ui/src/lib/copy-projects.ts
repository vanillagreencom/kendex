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
export const reinstallFrom = (marketplace: string): string =>
  `You can install it again from ${marketplace}.`;
export const REINSTALL_OWN =
  "This copy is your own, so there is no marketplace to install it from again.";
