import { useEffect } from "react";
import { toast } from "sonner";
import { create } from "zustand";
import {
  type AuditView,
  commands,
  type HarnessId,
  type ItemKind,
  type Scope,
} from "@/bindings";
import { adoptedToastLabel } from "@/lib/copy";
import { sameScope } from "@/lib/scope";
import { settled } from "@/lib/settled";
import { type ErrorAction, useProblemsStore } from "./problems";
import { useScanStore } from "./scan";

interface AuditState {
  views: AuditView[];
  auditing: boolean;
  error: string | null;
  /** Why the last audit itself failed, or null — written only by
   *  `refresh`. The shared `error` above is also set by item actions, so a
   *  failed remove or adopt would otherwise read as a machine that could
   *  not be checked. */
  checkError: string | null;
  busy: boolean;
  /** The startup audit has already toasted its failure — suppresses repeat
   * toasts on every silent retry until one succeeds. */
  backgroundFailureAnnounced: boolean;
  /** Unix ms of the last audit that came back clean; null until one has. */
  auditedAt: number | null;
  refresh: (opts?: { force?: boolean }) => Promise<void>;
  /** Every action here answers whether it worked. Most callers only need
   *  the state update that comes with it; the ones running several in a
   *  row need to stop at the first failure.
   *
   *  Hand the files already at an item's place to kendex as they are, for
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

/** One scope's view, swapped for the fresh one a command handed back. */
function replaceView(views: AuditView[], fresh: AuditView): AuditView[] {
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
function auditRunner(
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

/** How long an audit answers for before a visit pays for a fresh one. */
const AUDIT_FRESH_FOR_MS = 60_000;

export const useAuditStore = create<AuditState>((set, get) => {
  const run = auditRunner(set, get);

  return {
    views: [],
    auditedAt: null,
    auditing: false,
    error: null,
    checkError: null,
    busy: false,
    backgroundFailureAnnounced: false,

    // Auditing the whole machine is seconds of work to answer a question
    // already on screen. A recent answer is reused; anything the app itself
    // changes refreshes the scope it changed, and a stale window closes on
    // its own inside a minute.
    refresh: async (opts) => {
      if (get().auditing) return;
      const auditedAt = get().auditedAt;
      const fresh =
        auditedAt != null && Date.now() - auditedAt < AUDIT_FRESH_FOR_MS;
      if (fresh && !opts?.force) return;
      set({ auditing: true });
      try {
        // `settled` lands a rejected call as the same failed audit as a
        // returned refusal, which keeps Home's attention section off its
        // skeleton, the same as the scan.
        const response = await settled(commands.auditAll());
        if (response.status === "ok") {
          set({
            views: response.data,
            auditedAt: Date.now(),
            error: null,
            checkError: null,
            backgroundFailureAnnounced: false,
          });
        } else {
          set({ error: response.error, checkError: response.error });
          if (!get().backgroundFailureAnnounced) {
            toast.error(response.error);
            set({ backgroundFailureAnnounced: true });
          }
        }
      } finally {
        set({ auditing: false });
      }
    },

    adopt: (scope, kind, name, harnesses, quiet) =>
      run(() => commands.adoptItem(scope, kind, name, harnesses), {
        title: `Couldn't start managing ${name}`,
        successMessage: quiet ? undefined : adoptedToastLabel(name),
        steps: ["Try again"],
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
});

/** Ask for a fresh audit as a page that renders one comes up.
 *
 *  Content can change under the app between visits — an editor saved a
 *  skill, another tool wrote a hook — and a page showing a score is showing
 *  a claim about files it has not looked at since. The store's own
 *  freshness window decides whether the ask costs anything, so a page says
 *  what it needs without knowing when the last audit ran. */
export function useAuditOnMount() {
  const refresh = useAuditStore((s) => s.refresh);
  useEffect(() => {
    void refresh();
  }, [refresh]);
}
