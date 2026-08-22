// One place the app counts what the audit found, so the sidebar badge, the
// status footer, Home and the Review cards can never quote different
// numbers for the same thing.
//
// The engine emits one drift row per harness an item targets, so a skill
// present for five tools is five rows and one thing. A person counts the
// thing. Merging happens inside each scope: the same name in two projects
// is genuinely two items, and folding those together would undercount.
import type { AuditView, DriftRow } from "@/bindings";
import { heldBack } from "@/lib/derive";
import { mergeDriftRows } from "@/lib/drift-merge";
import { Exits } from "@/lib/drift-zones";
import { partitionSafety } from "@/lib/group-findings";
import { mergeHeldBack } from "@/lib/group-findings-blocked";
import { evidenceGroups, openOccurrences } from "@/lib/reviewable";

export interface AuditCounts {
  /** Writes kendex is ready to make: install, update, remove. */
  changes: number;
  /** Declared, with files already where they go. Apply cannot move these —
   *  only a person choosing which way they go — so counting them as work
   *  ready to apply promises a button that will not touch them. */
  inTheWay: number;
  /** On disk, but kendex was never asked to look after it. Not a debt —
   *  adopting is an offer the user takes up, so it is counted apart from
   *  the work that is actually queued. */
  unmanaged: number;
  /** Installs the safety gate is holding back until someone rules on them —
   *  one per item, however many tools it is installed for. */
  blocked: number;
  /** Findings on installed content nobody has ruled on yet — one per
   *  distinct piece of evidence, so the same file seen through three tools
   *  is one decision, not three. */
  open: number;
}

/** Whether this row sits on a decision, which is true of the places with
 *  a way out and of anything beside them nothing can settle.
 *
 *  Asked within one scope, like the card that draws the row: the same name
 *  in two projects is two items, and a neighbour found in the other one
 *  would move this row onto a decision it has nothing to do with. */
function blocking(view: AuditView, row: DriftRow): boolean {
  const exits = new Exits(view.exits);
  if (!exits.blocking(row)) return false;
  return view.drift.some(
    (other) =>
      other.kind === row.kind &&
      other.name === row.name &&
      exits.offered(other),
  );
}

function countMerged(
  views: AuditView[],
  keep: (view: AuditView, row: DriftRow) => boolean,
) {
  return views.reduce(
    (sum, view) =>
      sum + mergeDriftRows(view.drift.filter((row) => keep(view, row))).length,
    0,
  );
}

/** Held-back items in one scope: the on-disk blocked rows plus the
 *  plan-time refusals that never reached disk, one per item however many
 *  tools it targets. An item whose findings someone accepted is installed
 *  and staying — it is shown in the panel with a note, but nobody is
 *  waiting on it, so it is not counted. */
export function blockedCount(view: AuditView): number {
  const { display } = mergeHeldBack(
    partitionSafety(view.safety).blocked,
    view.heldBack,
  );
  return new Set(
    display.filter(heldBack).map((row) => `${row.kind}::${row.name}`),
  ).size;
}

export function openCount(view: AuditView): number {
  return evidenceGroups(openOccurrences(view.safety)).length;
}

export function auditCounts(views: AuditView[]): AuditCounts {
  return {
    // Counted the way Review draws them, so the two never quote different
    // numbers: a place nothing can settle sits on the decision row beside
    // the files in the way, not under the button that cannot move it.
    changes: countMerged(
      views,
      (view, row) => row.state !== "unmanaged" && !blocking(view, row),
    ),
    inTheWay: countMerged(views, blocking),
    unmanaged: countMerged(views, (_view, row) => row.state === "unmanaged"),
    blocked: views.reduce((sum, view) => sum + blockedCount(view), 0),
    open: views.reduce((sum, view) => sum + openCount(view), 0),
  };
}

/** What the Review page has waiting for a person: work to apply, plus
 *  the decisions only they can make — held-back items and open findings. */
export function needsReviewCount(counts: AuditCounts): number {
  return counts.changes + counts.inTheWay + counts.blocked + counts.open;
}

/** The decisions alone: what "Needs your decision" holds across scopes. */
export function decisionsPendingCount(counts: AuditCounts): number {
  return counts.inTheWay + counts.blocked + counts.open;
}
