import { toast } from "sonner";
import {
  type AuditView,
  commands,
  type HarnessId,
  type ItemKind,
  type Scope,
} from "@/bindings";
import { adoptedToastLabel } from "@/lib/copy";
import { replacedToastLabel } from "@/lib/copy-in-the-way";
import { sayUndone } from "@/lib/undone";
import { replaceView } from "./audit-fold";
import { type ErrorAction, useProblemsStore } from "./problems";
import { useScanStore } from "./scan";

/** Every action here answers whether it worked. Most callers only need the
 *  state update that comes with it; the ones running several in a row need
 *  to stop at the first failure. */
export interface ItemActions {
  /** Hand the files already at an item's place to kendex as they are, for
   *  every tool the item is blocked for — one call, so no tool's copy is
   *  captured over another's. */
  adopt: (
    scope: Scope,
    kind: ItemKind,
    name: string,
    harnesses: HarnessId[],
    /** Say nothing on success. A run over a whole page is one action to
     *  the person doing it, and a toast per item buries the page it was
     *  about. */
    quiet?: boolean,
  ) => Promise<boolean>;
  /** The other direction from adopting: install what the manifest declares
   *  over the files already sitting where one item goes, sending those to
   *  the trash first. Named per item, so a neighbour blocked the same way
   *  keeps its files until the person decides about it too. */
  replaceUnmanaged: (
    scope: Scope,
    kind: ItemKind,
    name: string,
  ) => Promise<boolean>;
  toggle: (
    scope: Scope,
    kind: ItemKind,
    name: string,
    enabled: boolean,
  ) => Promise<boolean>;
  removeItem: (scope: Scope, kind: ItemKind, name: string) => Promise<boolean>;
}

/** What every item-level command hands back: the scope's fresh view. */
type AuditAction = () => Promise<
  { status: "ok"; data: AuditView } | { status: "error"; error: string }
>;

interface RunOpts {
  title: string;
  successMessage?: string;
  steps?: string[];
}

type Run = (action: AuditAction, opts: RunOpts) => Promise<boolean>;

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
  /** Called at both ends of a command attempt, however it ends. An attempt
   *  is a span, not a moment: each of these runs a plan before a step that
   *  can still fail, so a command writes throughout its own run and one
   *  that failed is not one that wrote nothing. Marking only the end left a
   *  reading that landed mid-attempt looking current. Unconditional on
   *  purpose: an attempt that turned out to write nothing costs one
   *  re-read, which is the direction with nothing to lose. */
  attempted: () => void,
): Run {
  const run: Run = async (action, opts) => {
    set({ busy: true });
    attempted();
    let response: Awaited<ReturnType<typeof action>>;
    try {
      response = await action();
    } finally {
      set({ busy: false });
      attempted();
    }
    if (response.status === "ok") {
      set({
        views: replaceView(get().views, response.data),
        error: null,
      });
      if (opts.successMessage) toast.success(opts.successMessage);
      // What the removal ran in the repository, said whatever the action
      // was called: every command here answers with the same view.
      sayUndone(response.data.undone);
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

/** The commands that change one item, each reporting through the runner. */
export function itemActions(run: Run): ItemActions {
  return {
    adopt: (scope, kind, name, harnesses, quiet) =>
      run(() => commands.adoptItem(scope, kind, name, harnesses), {
        title: `Couldn't start managing ${name}`,
        successMessage: quiet ? undefined : adoptedToastLabel(name),
        steps: ["Try again"],
      }),
    replaceUnmanaged: (scope, kind, name) =>
      run(() => commands.replaceUnmanagedItem(scope, kind, name), {
        title: `Couldn't replace ${name}'s files`,
        successMessage: replacedToastLabel(name),
        steps: [
          "Nothing was changed — try again",
          "If it keeps failing, check the project folder is writable",
        ],
      }),
    toggle: (scope, kind, name, enabled) =>
      run(() => commands.toggleItem(scope, kind, name, enabled), {
        title: `Couldn't ${enabled ? "turn on" : "turn off"} ${name}`,
        steps: ["Try again"],
      }),
    removeItem: (scope, kind, name) =>
      run(() => commands.removeItem(scope, kind, name), {
        title: `Couldn't remove ${name}`,
        steps: ["Try again"],
      }),
  };
}
