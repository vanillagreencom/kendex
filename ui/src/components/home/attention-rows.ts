import type { ScanResult, UnreadableScope, UpdateRow } from "@/bindings";
import type { AttentionRow } from "@/components/home/attention-section";
import {
  AUDIT_ATTENTION_DETAIL,
  AUDIT_ATTENTION_TITLE,
  FORKED_ATTENTION_DETAIL,
  forkedAttentionTitle,
  TRY_AGAIN_LABEL,
  UPDATES_ATTENTION_DETAIL,
  UPDATES_ATTENTION_TITLE,
} from "@/lib/copy";
import { SEE_PROBLEMS_LABEL } from "@/lib/copy-marketplaces";
import {
  UPDATES_UNREADABLE_TITLE,
  unreadablePlacesLabel,
} from "@/lib/copy-updates";
import { scopeNames } from "@/lib/labels";

/** Everything Home's attention list is derived from, with the way into
 *  each row's destination handed in — the derivation emits the rows in a
 *  fixed product order, and the page stays a layout. */
export interface AttentionSource {
  editedPackages: UpdateRow[];
  result: ScanResult | null;
  /** Why the last update check failed, or null. A failed check is a state
   *  to show, not a silence: with nothing said, a list without an "edited
   *  packages" row would read as kendex having looked and found nothing. */
  updatesError: string | null;
  /** Why the last audit failed, or null — the counts above came from an
   *  audit that could not finish, so what needs attention may be missing
   *  from this very list. */
  auditError: string | null;
  /** Places with no update standing at all — the personal scope included,
   *  since it has a lock of its own. Their rows are missing from every
   *  count above, and the reason is on Problems, not here. */
  unreadable: UnreadableScope[];
  onProjects: () => void;
  onProblems: () => void;
  onUpdates: () => void;
  onLibrary: () => void;
  onPackage: (row: UpdateRow) => void;
  onAuditRetry: () => void;
}

export function attentionRows(source: AttentionSource): AttentionRow[] {
  const { editedPackages, result, updatesError, auditError, unreadable } =
    source;
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
  // A failed audit means the counts above answer for less than the whole
  // machine — the row says so and offers the retry, instead of the section
  // holding its skeleton for the session.
  if (auditError !== null) {
    rows.push({
      key: "audit-unchecked",
      tone: "warning",
      title: AUDIT_ATTENTION_TITLE,
      detail: AUDIT_ATTENTION_DETAIL,
      action: { label: TRY_AGAIN_LABEL, onClick: source.onAuditRetry },
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
  if (unreadable.length > 0) {
    rows.push({
      key: "updates-unreadable",
      tone: "warning",
      title: UPDATES_UNREADABLE_TITLE,
      detail: unreadablePlacesLabel(
        scopeNames(unreadable.map((place) => place.scope)),
      ),
      action: { label: SEE_PROBLEMS_LABEL, onClick: source.onProblems },
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
