// One place the app reads what the audit found is unmanaged, so a project's
// card and the page behind it can never quote different numbers for the
// same thing.
//
// The engine emits one drift row per harness an item targets, so a skill
// present for five tools is five rows and one thing. A person counts the
// thing. Counting happens inside one scope: the same name in two projects
// is genuinely two items, and folding those together would undercount.
import type { AuditView } from "@/bindings";
import { type MergedDriftRow, mergeDriftRows } from "@/lib/drift-merge";

/** Everything at this place kendex did not put there, one entry per item
 *  however many tools it is installed for. Adopting is an offer the user
 *  takes up, so this is never work waiting on them.
 *
 *  Null where the audit could not read this place. What is there is
 *  genuinely unknown, and an empty list is a claim: it would read as
 *  "nothing unmanaged here", and every row the app would have offered to
 *  adopt writes to the filesystem. Null so no caller can spend it as a
 *  number without deciding what to say. */
export function unmanagedIn(view: AuditView): MergedDriftRow[] | null {
  if (view.error) return null;
  return mergeDriftRows(view.drift.filter((row) => row.state === "unmanaged"));
}

export const unmanagedCount = (view: AuditView): number | null =>
  unmanagedIn(view)?.length ?? null;
