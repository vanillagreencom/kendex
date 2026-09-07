// The start-of-session note at one project: which state its card names,
// and the action behind the card's one button.
import { toast } from "sonner";
import type { AuditView, ObservedItem, Scope } from "@/bindings";
import { commands } from "@/bindings";
import {
  SESSION_NOTE_FAILED,
  sessionNoteAdded,
  sessionNoteWaiting,
} from "@/lib/copy-session-note";
import { hookDisplayName } from "@/lib/labels";
import { writingRepo } from "@/lib/rescan";
import { sameScope } from "@/lib/scope";
import { useProblemsStore } from "@/stores/problems";

/** The name core declares the hook under: `drift::hook::HOOK_NAME`. A
 *  rendered registration is scanned as `<event>:<matcher>:<stem>`, whose
 *  stem is this same name. */
export const SESSION_NOTE_HOOK = "kendex-drift";

/** `on`: a harness in this project runs the hook. `waiting`: the project
 *  declares it and nothing has rendered it, because the install ran with
 *  other changes pending and only the declaration landed. `off`: neither.
 *  Read off the scan and the audit the app already holds, so the card
 *  and the Library agree about the same hook. */
export type SessionNoteState = "off" | "waiting" | "on";

export function sessionNoteState(
  items: ObservedItem[],
  views: AuditView[],
  root: string,
): SessionNoteState {
  const scope: Scope = { scope: "project", root };
  const rendered = items.some(
    (item) =>
      item.kind === "hook" &&
      sameScope(item.scope, scope) &&
      hookDisplayName(item.name) === SESSION_NOTE_HOOK,
  );
  if (rendered) return "on";
  const declared = views
    .find((view) => sameScope(view.scope, scope))
    ?.drift.some(
      (row) =>
        row.kind === "hook" &&
        row.name === SESSION_NOTE_HOOK &&
        row.state === "missing",
    );
  return declared ? "waiting" : "off";
}

/** Add the note to one project, after the person said yes. The hook is
 *  applied before the command can answer either way, so a refusal comes
 *  back with it already on disk: the machine is read again whatever it
 *  said, on `lib/rescan.ts`'s rule. `false` from the command is the
 *  waiting state: the scope had other pending changes, so only the
 *  declaration landed and nothing is applied unseen. */
export async function addSessionNote(
  root: string,
  project: string,
): Promise<void> {
  await writingRepo(async () => {
    const result = await commands.installDriftHook({ scope: "project", root });
    if (result.status === "ok") {
      toast.success(
        result.data ? sessionNoteAdded(project) : sessionNoteWaiting(project),
      );
    } else {
      useProblemsStore.getState().showError({
        title: SESSION_NOTE_FAILED,
        message: result.error,
        steps: ["Try again"],
      });
    }
  });
}
