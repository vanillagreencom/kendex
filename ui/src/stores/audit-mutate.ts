import { toast } from "sonner";
import type { AuditView, Scope } from "@/bindings";
import { replaceView } from "./audit";
import { manifestRewritten } from "./manifest-sync";
import { type ErrorAction, useProblemsStore } from "./problems";
import { useScanStore } from "./scan";
import { refusesForUnsaved, retryTheRest } from "./unsaved-first";

/** Everything the funnel writes back into the store it belongs to. */
interface MutationHost {
  views: AuditView[];
  error: string | null;
  busy: boolean;
}

/** The one way an audit action reaches the machine: apply, adopt, toggle,
 *  remove and dismiss all go through here, so what each of them owes —
 *  refusing while a draft is unsaved, holding the Save bar down until the
 *  editor knows, saying what happened either way — is owed once. */
export function auditMutation(
  set: (
    update:
      | Partial<MutationHost>
      | ((state: { views: AuditView[] }) => Partial<MutationHost>),
  ) => void,
  get: () => { views: AuditView[] },
) {
  // A row that vanishes with no word said is indistinguishable from a
  // button that did nothing — every outcome here speaks up, success or
  // failure, on top of the state update the page renders from. Failure is a
  // modal, not a toast: these are all user-initiated, so the user is looking
  // right at the button that just broke.
  const run = async (
    // Every action through here rewrites this scope's kendex.toml, and the
    // editor holds a whole copy of it that a save would write back.
    scope: Scope,
    action: () => Promise<
      // `wrote` is for an action made of several writes: one that failed
      // partway through still changed the file, and the editor is owed
      // that by the write rather than by the outcome.
      | { status: "ok"; data: AuditView }
      | { status: "error"; error: string; wrote?: boolean }
    >,
    opts: { title: string; successMessage?: string; steps?: string[] },
    // Whether the machine took it. A caller running one action over
    // several places cannot read that off a void: it would carry on to the
    // next place after the first refused or failed, and leave the package
    // changed in some of them.
  ) => {
    // Apply, adopt, toggle and remove all rewrite this scope's kendex.toml,
    // so unsaved customization for it refuses them the way a fork or a
    // discard is refused — before anything is written, and wherever the
    // typing is waiting.
    if (refusesForUnsaved(scope)) return false;
    set({ busy: true });
    // Busy is one of the flags holding the Customize tab's Save bar down, so
    // it stays up until the editor has been told its copy is stale — clearing
    // it any earlier leaves a window where a save passes the outdated check
    // and writes the pre-action manifest back.
    try {
      const response = await action();
      if (response.status === "ok") {
        set({ views: replaceView(get().views, response.data), error: null });
        if (opts.successMessage) toast.success(opts.successMessage);
        await manifestRewritten(scope);
        await useScanStore.getState().refresh();
        return true;
      }
      set({ error: response.error });
      if (response.wrote === true) await manifestRewritten(scope);
      const retry: ErrorAction = {
        label: "Retry",
        // Inside a package-wide action this place is not the whole job:
        // retrying it alone would report success with the places after it
        // never attempted. The one that knows what is left says so.
        onClick: retryTheRest() ?? (() => void run(scope, action, opts)),
      };
      useProblemsStore.getState().showError({
        title: opts.title,
        message: response.error,
        steps: opts.steps,
        actions: [retry],
      });
      return false;
    } finally {
      set({ busy: false });
    }
  };
  return run;
}
