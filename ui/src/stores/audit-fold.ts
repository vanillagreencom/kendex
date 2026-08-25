// How a fresh audit folds over the one already on screen.
//
// Kept apart from the store because it is the whole of what "a new audit
// arrived" means, and it is decided per scope: the machine-wide answer says
// only that the command ran.
import type { AuditView } from "@/bindings";
import { sameScope, scopeKey } from "@/lib/scope";

/** One scope's view, swapped for the fresh one a command handed back. */
export function replaceView(views: AuditView[], fresh: AuditView): AuditView[] {
  return views.map((view) =>
    sameScope(view.scope, fresh.scope) ? fresh : view,
  );
}

/** Fold a fresh audit over what is already on screen.
 *
 *  A scope the audit could not read — a corrupt lock, a manifest from a
 *  newer kendex — comes back empty with its `error` set. Rendering that
 *  view whole would put zeros on screen as this moment's answer: no score
 *  on the package page, a dash on the Updates row, and nothing anywhere
 *  saying a check failed.
 *
 *  Only the scores carry over. A score is a reading of bytes that were on
 *  disk, worth showing dated as long as it says what it is; drift is a
 *  comparison against a manifest this audit could not read, and every
 *  action the app offers is derived from it — adopting writes to the
 *  filesystem from those rows. Last-known drift would put the app to work
 *  on a picture nothing has confirmed, so drift, plan, notes and exits
 *  stay empty and the surfaces reading them say the place is unknown
 *  rather than clean.
 *
 *  The failure rides on the view either way, so the Problems page lists it
 *  and the score surfaces date their reading. Every scope that answered
 *  keeps its fresh view. */
export function keepUnreadable(
  previous: AuditView[],
  fresh: AuditView[],
): AuditView[] {
  return fresh.map((view) => {
    if (!view.error) return view;
    // Whatever stands for this scope, error and all: a scope failing twice
    // running must not lose on the second pass what it kept on the first.
    const kept = previous.find((old) => sameScope(old.scope, view.scope));
    return kept ? { ...view, safety: kept.safety } : view;
  });
}

/** Stamp the scopes that answered. One that failed keeps its old stamp:
 *  saying a retained reading was taken just now is the claim every one of
 *  these surfaces exists to avoid making. */
export function stampClean(
  before: Record<string, number>,
  fresh: AuditView[],
  now: number,
): Record<string, number> {
  const after = { ...before };
  for (const view of fresh) {
    if (!view.error) after[scopeKey(view.scope)] = now;
  }
  return after;
}
