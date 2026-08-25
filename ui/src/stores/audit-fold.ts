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
 *  newer kendex — comes back empty with its `error` set. Its drift, its
 *  plan and every score are unknown, not gone. Taking that view whole
 *  replaces a real reading with zeros and presents them as this moment's
 *  answer: the package page renders nothing, the Updates score shows a
 *  dash, and nothing anywhere says a check failed.
 *
 *  So the last reading for that scope stands with the fresh failure
 *  attached, which is what the surfaces read to date it and offer the
 *  retry. The failure rides on the view, so the Problems page still lists
 *  it. Every scope that answered keeps its fresh view. */
export function keepUnreadable(
  previous: AuditView[],
  fresh: AuditView[],
): AuditView[] {
  return fresh.map((view) => {
    if (!view.error) return view;
    // Whatever stands for this scope, error and all: a scope failing twice
    // running must not lose on the second pass what it kept on the first.
    const kept = previous.find((old) => sameScope(old.scope, view.scope));
    return kept ? { ...kept, error: view.error } : view;
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
