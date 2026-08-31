// How a fresh audit folds over the one already on screen.
//
// Kept apart from the store because it is the whole of what "a new audit
// arrived" means, and it is decided per scope: the machine-wide answer says
// only that the command ran.
import type { AuditView } from "@/bindings";
import { sameScope } from "@/lib/scope";

/** One scope's view, swapped for the fresh one a command handed back. */
export function replaceView(views: AuditView[], fresh: AuditView): AuditView[] {
  return views.map((view) =>
    sameScope(view.scope, fresh.scope) ? fresh : view,
  );
}
