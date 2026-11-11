import { useMemo } from "react";
import { create } from "zustand";
import type { AuditView, ScanWarning, Scope, ScopeErrorKind } from "@/bindings";
import { type BlockedPlace, blockedPlaces } from "@/lib/audit-counts";
import { isActionable } from "@/lib/copy-scan";
import { useAuditStore } from "./audit";
import { useScanStore } from "./scan";

/** A ScopeError kind, plus "scan-failure" for the one problem source that
 *  isn't scoped to a project — a machine scan that couldn't finish. */
export type ProblemKind = ScopeErrorKind | "scan-failure";

export interface Problem {
  key: string;
  /** null for a scan failure, which isn't about any one project. */
  scope: Scope | null;
  kind: ProblemKind;
  message: string;
}

function scopeKey(scope: Scope): string {
  return scope.scope === "global" ? "global" : scope.root;
}

// Pure so the derivation is testable without mounting a component — every
// ongoing problem comes from state that already exists elsewhere, never from
// a list this file maintains on its own.
export function deriveProblems(
  views: AuditView[],
  scanError: string | null,
): Problem[] {
  const problems: Problem[] = [];
  for (const view of views) {
    if (!view.error) continue;
    problems.push({
      key: scopeKey(view.scope),
      scope: view.scope,
      kind: view.error.kind,
      message: view.error.message,
    });
  }
  if (scanError) {
    problems.push({
      key: "scan",
      scope: null,
      kind: "scan-failure",
      message: scanError,
    });
  }
  return problems;
}

/** Ongoing problems the status footer and Problems page both read — always
 *  recomputed from the audit and scan stores. */
export function useProblems(): Problem[] {
  const views = useAuditStore((s) => s.views);
  const scanError = useScanStore((s) => s.error);
  return useMemo(() => deriveProblems(views, scanError), [views, scanError]);
}

const NO_WARNINGS: ScanWarning[] = [];

/** Every file the scan could not read as the document its surface
 *  expects. Read straight off the last scan: a file that is fixed is gone
 *  from the next result, and one that is not is still there. */
function useScanWarnings(): ScanWarning[] {
  return useScanStore((s) => s.result?.warnings ?? NO_WARNINGS);
}

/** The ones with a repair behind them. Split by the standing core stamped
 *  on each warning, never by re-reading its message here. */
export function useUnreadableFiles(): ScanWarning[] {
  const warnings = useScanWarnings();
  return useMemo(() => warnings.filter(isActionable), [warnings]);
}

/** Every place holding a declared item whose files were already on disk,
 *  recomputed from the audit like the problems above. Its own list: a
 *  blocked item is a decision waiting on the reader, not a place kendex
 *  failed to read, and the two are answered in different words.
 *
 *  Null where the last check failed, which is not the same as none: the
 *  buttons behind these rows write to the filesystem. */
export function useBlockedPlaces(): BlockedPlace[] | null {
  const views = useAuditStore((s) => s.views);
  // The audit read's own outcome. A failed keep or take-over is not a
  // machine that could not be checked — it opens this store's own dialog.
  const failure = useAuditStore((s) => s.read.error);
  return useMemo(() => blockedPlaces(views, failure), [views, failure]);
}

export interface ErrorAction {
  label: string;
  onClick: () => void;
}

/** One failure the error dialog states: what failed, the error it gave,
 *  what to do about it, and the controls that act on it. */
export interface Failure {
  title: string;
  message?: string;
  steps: string[];
  actions: ErrorAction[];
}

/** What the dialog shows: one failure, and any later failures of the same
 *  run joined behind it. */
interface ErrorDialogState extends Failure {
  open: boolean;
  /** Failures of the run that opened the dialog, each said after the one
   *  heading it, in the order they arrived. Empty outside a run. */
  joined: Failure[];
  /** The run that opened the dialog, or null when no run was in flight. */
  run: number | null;
}

interface ProblemsStore {
  dialog: ErrorDialogState;
  /** The run in flight, or null. A number rather than a flag so a run
   *  joins only the dialog it opened, never one that was up before it. */
  run: number | null;
  showError: (opts: {
    title: string;
    message?: string;
    steps?: string[];
    actions?: ErrorAction[];
  }) => void;
  closeError: () => void;
  /** Run `work` as one run: every failure it says while the dialog it
   *  opened is still up joins that dialog rather than replacing it. A run
   *  inside a run is part of the outer one. */
  inOneRun: <T>(work: () => Promise<T>) => Promise<T>;
}

const CLOSED: ErrorDialogState = {
  open: false,
  title: "",
  steps: [],
  actions: [],
  joined: [],
  run: null,
};

let runs = 0;

/** The one error modal for the whole app. A user-initiated action calls
 *  showError instead of toasting, so a failure always states what broke and
 *  how to fix it rather than flashing past in a corner.
 *
 *  The dialog shows one action's failure, and a later one replaces it. A
 *  run over several places or items is one action that can fail several
 *  times — one place refused, another's write landed with a step behind it
 *  failing — and a replace there would drop a failure the person never
 *  saw. So inside [`inOneRun`] every failure after the first joins the
 *  dialog, whatever kind it is; closing the dialog drops them all, and the
 *  run's next failure opens it afresh. */
export const useProblemsStore = create<ProblemsStore>((set, get) => ({
  dialog: CLOSED,
  run: null,
  showError: ({ title, message, steps = [], actions = [] }) =>
    set(({ dialog, run }) => {
      const failure: Failure = { title, message, steps, actions };
      if (run !== null && dialog.open && dialog.run === run) {
        return { dialog: { ...dialog, joined: [...dialog.joined, failure] } };
      }
      return { dialog: { ...failure, open: true, joined: [], run } };
    }),
  closeError: () => set({ dialog: CLOSED }),
  inOneRun: async (work) => {
    if (get().run !== null) return work();
    runs += 1;
    set({ run: runs });
    try {
      return await work();
    } finally {
      set({ run: null });
    }
  },
}));
