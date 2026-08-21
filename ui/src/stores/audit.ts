import { toast } from "sonner";
import { create } from "zustand";
import {
  type AuditView,
  commands,
  type DismissReason,
  type HarnessId,
  type ItemKind,
  type Scope,
} from "@/bindings";
import { adoptedToastLabel } from "@/lib/copy";
import {
  ignoredToast,
  TAKEN_BACK_TOAST,
  UNDO_LABEL,
} from "@/lib/copy-decisions";
import { replacedToastLabel } from "@/lib/copy-in-the-way";
import { auditRunner, replaceView } from "./audit-run";
import { useProblemsStore } from "./problems";

interface AuditState {
  views: AuditView[];
  auditing: boolean;
  error: string | null;
  busy: boolean;
  /** The startup audit has already toasted its failure — suppresses repeat
   * toasts on every silent retry until one succeeds. */
  backgroundFailureAnnounced: boolean;
  /** Unix ms of the last audit that came back clean; null until one has. */
  auditedAt: number | null;
  refresh: (opts?: { force?: boolean }) => Promise<void>;
  /** Every action here answers whether it worked. Most callers only need
   *  the state update that comes with it; the ones running several in a
   *  row need to stop at the first failure. */
  applyPlan: (
    scope: Scope,
    removeOrphans: boolean,
    allowUnsafe?: string[],
  ) => Promise<boolean>;
  adopt: (
    scope: Scope,
    kind: ItemKind,
    name: string,
    harness: HarnessId,
    opts?: { silent?: boolean },
  ) => Promise<boolean>;
  /** Install what kendex.toml asks for over the files already at one
   *  item's place. Named item only, so a neighbour blocked the same way
   *  keeps its files until that one is decided too. */
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
  /** Rule that these findings are not problems. The toast offers Undo,
   *  which takes back exactly the records this call wrote. */
  dismiss: (
    scope: Scope,
    tokens: string[],
    reason: DismissReason,
  ) => Promise<void>;
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
    busy: false,
    backgroundFailureAnnounced: false,

    // Every visit to Review used to re-audit the whole machine, which is
    // seconds of work to answer a question already on screen. A recent
    // answer is reused; anything the app itself changes refreshes the scope
    // it changed, and a stale window closes on its own inside a minute.
    refresh: async (opts) => {
      if (get().auditing) return;
      const auditedAt = get().auditedAt;
      const fresh =
        auditedAt != null && Date.now() - auditedAt < AUDIT_FRESH_FOR_MS;
      if (fresh && !opts?.force) return;
      set({ auditing: true });
      try {
        const response = await commands.auditAll();
        if (response.status === "ok") {
          set({
            views: response.data,
            auditedAt: Date.now(),
            error: null,
            backgroundFailureAnnounced: false,
          });
        } else {
          set({ error: response.error });
          if (!get().backgroundFailureAnnounced) {
            toast.error(response.error);
            set({ backgroundFailureAnnounced: true });
          }
        }
      } finally {
        set({ auditing: false });
      }
    },

    applyPlan: (scope, removeOrphans, allowUnsafe = []) =>
      run(() => commands.applyPlan(scope, removeOrphans, allowUnsafe), {
        title: "Couldn't apply these changes",
        steps: [
          "Nothing was changed — try again",
          "If it keeps failing, check the project folder is writable",
        ],
      }),
    // A merged row adopts every one of its installations in one click —
    // each is its own backend call, but they're one thing to the user, so
    // only the first speaks up with a toast.
    adopt: (scope, kind, name, harness, opts) =>
      run(() => commands.adoptItem(scope, kind, name, harness), {
        title: `Couldn't start managing ${name}`,
        successMessage: opts?.silent ? undefined : adoptedToastLabel(name),
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
    // A dismissal is the one action whose success carries a way back on the
    // toast itself: the undo names the exact records that were written, so
    // an old toast can never take back a newer decision at the same key.
    dismiss: async (scope, tokens, reason) => {
      set({ busy: true });
      let response: Awaited<ReturnType<typeof commands.dismissFindings>>;
      try {
        response = await commands.dismissFindings(scope, tokens, reason);
      } finally {
        set({ busy: false });
      }
      if (response.status !== "ok") {
        set({ error: response.error });
        useProblemsStore.getState().showError({
          title: "Couldn't dismiss this finding",
          message: response.error,
          steps: [
            "Nothing was changed — read the finding again and decide again",
          ],
        });
        // The refusal usually means the page was showing findings a minute
        // old; the fresh audit is what the person should decide on.
        await get().refresh({ force: true });
        return;
      }
      const { view, records } = response.data;
      set({ views: replaceView(get().views, view), error: null });
      toast.success(ignoredToast(records.length), {
        action: {
          label: UNDO_LABEL,
          onClick: () =>
            void run(
              async () => {
                let latest: Awaited<
                  ReturnType<typeof commands.revokeDismissal>
                > = {
                  status: "error",
                  error: "nothing to take back",
                };
                for (const record of records) {
                  latest = await commands.revokeDismissal(
                    scope,
                    record.key,
                    record.fingerprint,
                    record.dismissedAt,
                  );
                  if (latest.status !== "ok") break;
                }
                return latest;
              },
              {
                title: "Couldn't take the dismissal back",
                successMessage: TAKEN_BACK_TOAST,
              },
            ),
        },
      });
    },
  };
});
