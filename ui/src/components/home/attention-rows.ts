import type { AuditView, ScanResult, UpdateRow } from "@/bindings";
import type { AttentionRow } from "@/components/home/attention-section";
import { auditCounts } from "@/lib/audit-counts";
import {
  FORKED_ATTENTION_DETAIL,
  forkedAttentionTitle,
  REVIEW_ACTION_LABEL,
  UPDATES_ATTENTION_DETAIL,
  UPDATES_ATTENTION_TITLE,
} from "@/lib/copy";

/** Everything Home's attention list is derived from, with the way into
 *  each row's destination handed in — the derivation orders the rows,
 *  worst first, and the page stays a layout. */
export interface AttentionSource {
  editedPackages: UpdateRow[];
  views: AuditView[];
  result: ScanResult | null;
  /** Why the last update check failed, or null. A failed check is a state
   *  to show, not a silence: with nothing said, a list without an "edited
   *  packages" row would read as kendex having looked and found nothing. */
  updatesError: string | null;
  onReview: () => void;
  onUnmanaged: () => void;
  onProjects: () => void;
  onUpdates: () => void;
  onLibrary: () => void;
  onPackage: (row: UpdateRow) => void;
}

export function attentionRows(source: AttentionSource): AttentionRow[] {
  const {
    changes: actionableCount,
    inTheWay,
    unmanaged: unmanagedCount,
    blocked,
    open,
  } = auditCounts(source.views);
  const { editedPackages, result, updatesError } = source;
  const missing = result?.missingProjects ?? [];

  const rows: AttentionRow[] = [];
  if (editedPackages.length > 0) {
    const first = editedPackages[0];
    rows.push({
      key: "edited",
      tone: "warning",
      title: forkedAttentionTitle(editedPackages.length),
      detail: FORKED_ATTENTION_DETAIL,
      action:
        editedPackages.length === 1 && first
          ? { label: first.name, onClick: () => source.onPackage(first) }
          : { label: "Library", onClick: source.onLibrary },
    });
  }
  if (blocked > 0) {
    rows.push({
      key: "safety",
      tone: "critical",
      title: blocked === 1 ? "1 problem found" : `${blocked} problems found`,
      detail: "Held back until you accept them.",
      action: { label: REVIEW_ACTION_LABEL, onClick: source.onReview },
    });
  }
  if (open > 0) {
    rows.push({
      key: "decisions",
      tone: "warning",
      title: open === 1 ? "1 finding to review" : `${open} findings to review`,
      detail: "In content already installed.",
      action: { label: REVIEW_ACTION_LABEL, onClick: source.onReview },
    });
  }
  if (inTheWay > 0) {
    rows.push({
      key: "in-the-way",
      tone: "warning",
      title:
        inTheWay === 1
          ? "1 item needs your decision"
          : `${inTheWay} items need your decision`,
      detail: "Files are already where they go.",
      action: { label: REVIEW_ACTION_LABEL, onClick: source.onReview },
    });
  }
  if (actionableCount > 0) {
    rows.push({
      key: "drift",
      tone: "info",
      title:
        actionableCount === 1
          ? "1 change ready to apply"
          : `${actionableCount} changes ready to apply`,
      action: { label: REVIEW_ACTION_LABEL, onClick: source.onReview },
    });
  }
  if (unmanagedCount > 0) {
    rows.push({
      key: "unmanaged",
      tone: "muted",
      title:
        unmanagedCount === 1
          ? "1 unmanaged item"
          : `${unmanagedCount} unmanaged items`,
      detail: "kendex didn't put them there.",
      action: { label: "Review", onClick: source.onUnmanaged },
    });
  }
  if (missing.length > 0) {
    rows.push({
      key: "missing-projects",
      tone: "warning",
      title:
        missing.length === 1
          ? "1 project folder can't be found"
          : `${missing.length} project folders can't be found`,
      detail:
        missing.length === 1
          ? `We can't find ${missing[0]}. If you moved it, add it again.`
          : "If you moved these, add them again from Harnesses & Projects.",
      action: { label: "Projects", onClick: source.onProjects },
    });
  }
  if (updatesError !== null) {
    rows.push({
      key: "updates-unchecked",
      tone: "warning",
      title: UPDATES_ATTENTION_TITLE,
      detail: UPDATES_ATTENTION_DETAIL,
      action: { label: "Updates", onClick: source.onUpdates },
    });
  }
  if (result && result.warnings.length > 0) {
    rows.push({
      key: "warnings",
      tone: "warning",
      title:
        result.warnings.length === 1
          ? "1 file couldn't be read"
          : `${result.warnings.length} files couldn't be read`,
      detail: result.warnings[0],
    });
  }
  return rows;
}
