import type { InstallState } from "@/bindings";

// The one reading of an `InstallState` every install surface does. The
// engine decides the state — a scope whose lock it could not read answers
// "unknown" for everything that lock alone could have settled — and a
// surface that worked out its own answer would be the arm that forgets.

/** Whether a row may offer an install. Only a package the records confirm
 *  is not installed here qualifies: "unknown" is a lock this build refuses,
 *  and the install would meet the same record. */
export const offersInstall = (state: InstallState): boolean =>
  state === "available";

/** Whether this state is the unreadable record itself — what a surface
 *  shows the reason and the route to Problems for, in place of a button. */
export const recordsUnreadable = (state: InstallState): boolean =>
  state === "unknown";
