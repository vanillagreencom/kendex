// One place the app counts what the audit found, so Home and the project
// cards can never quote different numbers for the same thing.
//
// The engine emits one drift row per harness an item targets, so a skill
// present for five tools is five rows and one thing. A person counts the
// thing. Merging happens inside each scope: the same name in two projects
// is genuinely two items, and folding those together would undercount.
import type { AuditView } from "@/bindings";
import { mergeDriftRows } from "@/lib/drift-merge";

export interface AuditCounts {
  /** Content on the machine that kendex did not put there, once per item
   *  however many tools it is installed for. Adopting is an offer the user
   *  takes up, so this is never counted as work waiting on them. */
  unmanaged: number;
}

export function auditCounts(views: AuditView[]): AuditCounts {
  return {
    unmanaged: views.reduce(
      (sum, view) =>
        sum +
        mergeDriftRows(view.drift.filter((row) => row.state === "unmanaged"))
          .length,
      0,
    ),
  };
}
