import { toast } from "sonner";
import { create } from "zustand";
import {
  type AuditView,
  commands,
  type DismissReason,
  type HarnessId,
  type ItemKind,
  type RecordedDecision,
  type Scope,
} from "@/bindings";
import { adoptedToastLabel } from "@/lib/copy";
import { TAKEN_BACK_TOAST } from "@/lib/copy-decisions";
import { dismissFinding } from "./audit-dismiss";
import { auditMutation } from "./audit-mutate";

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
  /** Every one of these answers whether the machine took it, so a caller
   *  running one action over several places can stop rather than carry on
   *  to the next after a refusal or a failure. */
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
  /** Take back an acceptance or a dismissal. It rewrites the place's
   *  kendex.toml like every other action here, so it belongs here: a write
   *  held in a component keeps its busy flag out of the shared gate. */
  revokeDecision: (row: RecordedDecision) => Promise<boolean>;
}

/** How long an audit answers for before a visit pays for a fresh one. */
const AUDIT_FRESH_FOR_MS = 60_000;

export function replaceView(views: AuditView[], fresh: AuditView): AuditView[] {
  return views.map((view) =>
    sameScope(view.scope, fresh.scope) ? fresh : view,
  );
}

export function sameScope(a: Scope, b: Scope): boolean {
  if (a.scope === "global" && b.scope === "global") return true;
  return a.scope === "project" && b.scope === "project" && a.root === b.root;
}

export const useAuditStore = create<AuditState>((set, get) => {
  const run = auditMutation(set, get);

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
      run(scope, () => commands.applyPlan(scope, removeOrphans, allowUnsafe), {
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
      run(scope, () => commands.adoptItem(scope, kind, name, harness), {
        title: `Couldn't start managing ${name}`,
        successMessage: opts?.silent ? undefined : adoptedToastLabel(name),
        steps: ["Try again"],
      }),
    toggle: (scope, kind, name, enabled) =>
      run(scope, () => commands.toggleItem(scope, kind, name, enabled), {
        title: `Couldn't ${enabled ? "turn on" : "turn off"} ${name}`,
        steps: ["Try again"],
      }),
    removeItem: (scope, kind, name) =>
      run(scope, () => commands.removeItem(scope, kind, name), {
        title: `Couldn't remove ${name}`,
        steps: ["Try again"],
      }),
    // A dismissal is the one action whose success carries a way back on the
    // toast itself: the undo names the exact records that were written, so
    // an old toast can never take back a newer decision at the same key. It
    // is written into this place's kendex.toml like every other decision, so
    // busy stays up — the Save bar with it — until the editor has been told
    // the copy it holds is stale.
    revokeDecision: async (row) =>
      run(
        row.scope,
        () =>
          row.record.kind === "accepted"
            ? commands.revokeSafetyOverride(row.scope, row.key)
            : commands.revokeDismissal(
                row.scope,
                row.key,
                row.record.fingerprint,
                row.record.dismissedAt,
              ),
        {
          title: "Couldn't take this decision back",
          successMessage:
            row.record.kind === "accepted"
              ? `${row.name} is held back again`
              : TAKEN_BACK_TOAST,
        },
      ),

    dismiss: dismissFinding(set, get, run),
  };
});
