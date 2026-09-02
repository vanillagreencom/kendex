import { useMemo } from "react";
import { create } from "zustand";
import type { AuditView, Scope, ScopeErrorKind } from "@/bindings";
import { type BlockedPlace, blockedPlaces } from "@/lib/audit-counts";
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

interface ErrorDialogState {
  open: boolean;
  title: string;
  message?: string;
  steps: string[];
  actions: ErrorAction[];
}

interface ProblemsStore {
  dialog: ErrorDialogState;
  showError: (opts: {
    title: string;
    message?: string;
    steps?: string[];
    actions?: ErrorAction[];
  }) => void;
  closeError: () => void;
}

const CLOSED: ErrorDialogState = {
  open: false,
  title: "",
  steps: [],
  actions: [],
};

/** The one error modal for the whole app. A user-initiated action calls
 *  showError instead of toasting, so a failure always states what broke and
 *  how to fix it rather than flashing past in a corner. */
export const useProblemsStore = create<ProblemsStore>((set) => ({
  dialog: CLOSED,
  showError: ({ title, message, steps = [], actions = [] }) =>
    set({ dialog: { open: true, title, message, steps, actions } }),
  closeError: () => set({ dialog: CLOSED }),
}));
