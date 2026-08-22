import { toast } from "sonner";
import type { AuditView } from "@/bindings";
import { sameScope } from "@/lib/scope";
import { type ErrorAction, useProblemsStore } from "./problems";
import { useScanStore } from "./scan";

/** What every item-level command hands back: the scope's fresh view. */
type AuditAction = () => Promise<
  { status: "ok"; data: AuditView } | { status: "error"; error: string }
>;

interface RunOpts {
  title: string;
  successMessage?: string;
  steps?: string[];
}

/** One scope's view, swapped for the fresh one a command handed back. */
export function replaceView(views: AuditView[], fresh: AuditView): AuditView[] {
  return views.map((view) =>
    sameScope(view.scope, fresh.scope) ? fresh : view,
  );
}

// A row that vanishes with no word said is indistinguishable from a button
// that did nothing — every outcome here speaks up, success or failure, on
// top of the state update the page renders from. Failure is a modal, not a
// toast: these are all user-initiated, so the user is looking right at the
// button that just broke.
//
// The answer says whether it worked, so a caller running several of these
// for one row can stop at the first that did not instead of carrying on
// against a page that is now wrong.
export function auditRunner(
  set: (partial: {
    busy?: boolean;
    views?: AuditView[];
    error?: string | null;
  }) => void,
  get: () => { views: AuditView[] },
) {
  const run = async (action: AuditAction, opts: RunOpts): Promise<boolean> => {
    set({ busy: true });
    let response: Awaited<ReturnType<typeof action>>;
    try {
      response = await action();
    } finally {
      set({ busy: false });
    }
    if (response.status === "ok") {
      set({ views: replaceView(get().views, response.data), error: null });
      if (opts.successMessage) toast.success(opts.successMessage);
      await useScanStore.getState().refresh();
      return true;
    }
    set({ error: response.error });
    const retry: ErrorAction = {
      label: "Retry",
      onClick: () => void run(action, opts),
    };
    useProblemsStore.getState().showError({
      title: opts.title,
      message: response.error,
      steps: opts.steps,
      actions: [retry],
    });
    return false;
  };
  return run;
}
