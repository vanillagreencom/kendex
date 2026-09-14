import type {
  ScanResult,
  ScanWarning,
  UnreadableScope,
  UpdateRow,
} from "@/bindings";
import type { AttentionRow } from "@/components/home/attention-section";
import type { StatusTone } from "@/components/status-note";
import type { BlockedPlace } from "@/lib/audit-counts";
import {
  AUDIT_ATTENTION_DETAIL,
  AUDIT_ATTENTION_TITLE,
  EDITED_ATTENTION_ACTION,
  editedAttentionDetail,
  editedAttentionTitle,
  MISSING_FILES_ATTENTION_ACTION,
  missingFilesAttentionDetail,
  missingFilesAttentionTitle,
  namesInWords,
  TRY_AGAIN_LABEL,
  UPDATES_ATTENTION_DETAIL,
  UPDATES_ATTENTION_TITLE,
} from "@/lib/copy";
import { BLOCKED_HEADLINE } from "@/lib/copy-in-the-way";
import { SEE_PROBLEMS_LABEL } from "@/lib/copy-marketplaces";
import {
  MISSING_PROJECTS_DETAIL,
  missingProjectDetail,
  missingProjectsTitle,
} from "@/lib/copy-project-move";
import {
  isActionable,
  scanNoteDetail,
  scanNoteTitle,
  unreadableFileDetail,
  unreadableFileTitle,
} from "@/lib/copy-scan";
import {
  UPDATES_UNREADABLE_TITLE,
  UPDATES_WAITING_DETAIL,
  unreadablePlacesLabel,
  updatesWaitingTitle,
} from "@/lib/copy-updates";
import { PROBLEM_HEADLINES } from "@/lib/error-copy";
import { scopeName, scopeNames } from "@/lib/labels";
import { scopeKey } from "@/lib/scope";
import { groupKey, visibleUpdates } from "@/lib/update-groups";
import type { Problem } from "@/stores/problems";
import { isRead, type ReadNotices } from "@/stores/read-notices";

/** What an item asks of the person. The classes, and the rule for each,
 *  are docs/design/attention.md. */
export type AttentionClass = "problem" | "decision" | "notice" | "update";

/** Each class's tone, the one table every surface reads its colour from.
 *  `done` and `failed` are the Result class: a toast or the error dialog,
 *  never a row. */
export const CLASS_TONES = {
  problem: "critical",
  decision: "warning",
  notice: "notice",
  update: "info",
  done: "good",
  failed: "critical",
} as const satisfies Record<AttentionClass | "done" | "failed", StatusTone>;

/** The Problems card an item keeps. An item without one draws there as
 *  its row. */
export type AttentionCard =
  | { kind: "problem"; problem: Problem }
  | { kind: "unreadable-file"; warning: ScanWarning }
  | { kind: "blocked-place"; place: BlockedPlace };

/** The update notice's read slot. */
export const UPDATES_READ_ID = "updates";

/** Everything the attention rows are derived from, with the way into each
 *  row's destination handed in — the derivation emits the rows in a fixed
 *  product order, and the pages stay layouts. */
export interface AttentionSource {
  /** Places kendex could not read, and a scan that could not finish. */
  problems: Problem[];
  /** Places whose declared items wait on a decision, or null where the
   *  audit failed — the audit's own row says so. */
  blocked: BlockedPlace[] | null;
  editedPackages: UpdateRow[];
  /** Installations a file kendex wrote has gone from. */
  missingPackages: UpdateRow[];
  result: ScanResult | null;
  /** Why the last update check failed, or null. A failed check is a state
   *  to show, not a silence: with nothing said, a list without an "edited
   *  packages" row would read as kendex having looked and found nothing. */
  updatesError: string | null;
  /** How many packages have updates, or null where no read has landed to
   *  say. Only a landed read puts a number on this page: a check that
   *  failed keeps its rows, but a definite count off them would be the
   *  claim the failed-check row exists to withhold. */
  updates: number | null;
  /** The update set that count is over, from [`updatesIdentity`]. */
  updatesIdentity: string;
  /** Why the last audit failed, or null — the counts above came from an
   *  audit that could not finish, so what needs attention may be missing
   *  from this very list. */
  auditError: string | null;
  /** Places with no update standing at all — the personal scope included,
   *  since it has a lock of its own. Their rows are missing from every
   *  count above, and the Updates page names the reason per place. */
  unreadable: UnreadableScope[];
  /** Which notices the person has dismissed or seen. */
  read: ReadNotices;
  onProjects: () => void;
  onProblems: () => void;
  onUpdates: () => void;
  /** The Library narrowed to the edited packages, and nothing wider. */
  onEditedPackages: () => void;
  /** The Library's installed list, where each place missing a file is
   *  marked on its package's row. */
  onMissingPackages: () => void;
  onPackage: (row: UpdateRow) => void;
  onAuditRetry: () => void;
}

/** The packages by place: "gh in vg; dev and orch in hyprtrade". Grouped
 *  by place rather than listed flat, so three names in one project read
 *  as three and not as one package in three places. */
export function packagesByPlace(rows: UpdateRow[]): string {
  const byPlace = new Map<
    string,
    { scope: UpdateRow["scope"]; names: string[] }
  >();
  for (const row of rows) {
    const key = scopeKey(row.scope);
    const entry = byPlace.get(key) ?? { scope: row.scope, names: [] };
    entry.names.push(row.name);
    byPlace.set(key, entry);
  }
  const places = [...byPlace.values()];
  // Two projects with one folder name are told apart by their path.
  const labels = scopeNames(places.map((place) => place.scope));
  return places
    .map(({ names }, index) => `${namesInWords(names)} in ${labels[index]}`)
    .join("; ");
}

/** The update notice's identity: every package with news on the Updates
 *  page, in every place, at the version it offers — the set the sidebar
 *  badge counts. New news or a newer version changes it, so the notice is
 *  unread again. */
export const updatesIdentity = (rows: UpdateRow[]): string =>
  visibleUpdates(rows)
    .map((row) =>
      JSON.stringify([scopeKey(row.scope), groupKey(row), row.latest]),
    )
    .sort()
    .join("\n");

/** Every item, classified, in the order Home lists them: Problems, then
 *  Decisions, then Updates, then Notices. A Notice or Update the person
 *  has read is left out. */
export function attentionRows(source: AttentionSource): AttentionRow[] {
  const {
    problems,
    blocked,
    editedPackages,
    missingPackages,
    result,
    updatesError,
    auditError,
    unreadable,
    read,
  } = source;
  const missing = result?.missingProjects ?? [];
  const warnings = result?.warnings ?? [];

  const rows: AttentionRow[] = [];
  for (const problem of problems) {
    rows.push({
      key: `problem:${problem.key}`,
      class: "problem",
      title: PROBLEM_HEADLINES[problem.kind],
      detail: problem.scope ? scopeName(problem.scope) : problem.message,
      action: { label: SEE_PROBLEMS_LABEL, onClick: source.onProblems },
      card: { kind: "problem", problem },
    });
  }
  if (missingPackages.length > 0) {
    const first = missingPackages[0];
    rows.push({
      key: "missing-files",
      class: "problem",
      title: missingFilesAttentionTitle(missingPackages.length),
      detail: missingFilesAttentionDetail(packagesByPlace(missingPackages)),
      action:
        missingPackages.length === 1 && first
          ? { label: first.name, onClick: () => source.onPackage(first) }
          : {
              label: MISSING_FILES_ATTENTION_ACTION,
              onClick: source.onMissingPackages,
            },
    });
  }
  if (missing.length > 0) {
    const first = missing[0];
    rows.push({
      key: "missing-projects",
      class: "problem",
      title: missingProjectsTitle(missing.length),
      detail:
        missing.length === 1 && first
          ? missingProjectDetail(first)
          : MISSING_PROJECTS_DETAIL,
      action: { label: "Projects", onClick: source.onProjects },
    });
  }
  // A failed audit means the counts above answer for less than the whole
  // machine — the row says so and offers the retry, instead of the section
  // holding its skeleton for the session.
  if (auditError !== null) {
    rows.push({
      key: "audit-unchecked",
      class: "problem",
      title: AUDIT_ATTENTION_TITLE,
      detail: AUDIT_ATTENTION_DETAIL,
      action: { label: TRY_AGAIN_LABEL, onClick: source.onAuditRetry },
    });
  }
  if (updatesError !== null) {
    rows.push({
      key: "updates-unchecked",
      class: "problem",
      title: UPDATES_ATTENTION_TITLE,
      detail: UPDATES_ATTENTION_DETAIL,
      action: { label: "Updates", onClick: source.onUpdates },
    });
  }
  // A place whose manifest or lock this build refuses already has its
  // Problem above, and the update check refusing the same place is that
  // one fault: only the places left over get this row. Updates, not
  // Problems: the Problems page draws this row too, and a link from it to
  // itself would do nothing.
  const reported = new Set(
    problems.flatMap((problem) =>
      problem.scope ? [scopeKey(problem.scope)] : [],
    ),
  );
  const unstanding = unreadable.filter(
    (place) => !reported.has(scopeKey(place.scope)),
  );
  if (unstanding.length > 0) {
    rows.push({
      key: "updates-unreadable",
      class: "problem",
      title: UPDATES_UNREADABLE_TITLE,
      detail: unreadablePlacesLabel(
        scopeNames(unstanding.map((place) => place.scope)),
      ),
      action: { label: "Updates", onClick: source.onUpdates },
    });
  }
  // One row per file, not one row for the count: each names its own tool,
  // path and remedy, and Problems carries the same file with the buttons.
  for (const warning of warnings.filter(isActionable)) {
    rows.push(unreadableFileRow(warning, source.onProblems));
  }

  for (const place of blocked ?? []) {
    rows.push({
      key: `blocked:${place.key}`,
      class: "decision",
      title: BLOCKED_HEADLINE,
      detail: scopeName(place.scope),
      action: { label: SEE_PROBLEMS_LABEL, onClick: source.onProblems },
      card: { kind: "blocked-place", place },
    });
  }
  if (editedPackages.length > 0) {
    const first = editedPackages[0];
    rows.push({
      key: "edited",
      class: "decision",
      title: editedAttentionTitle(editedPackages.length),
      detail: editedAttentionDetail(packagesByPlace(editedPackages)),
      action:
        editedPackages.length === 1 && first
          ? { label: first.name, onClick: () => source.onPackage(first) }
          : {
              label: EDITED_ATTENTION_ACTION,
              onClick: source.onEditedPackages,
            },
    });
  }

  // Counted the way the sidebar's badge counts, so one machine never
  // carries two numbers.
  const updatesKey = { id: UPDATES_READ_ID, identity: source.updatesIdentity };
  if (
    source.updates !== null &&
    source.updates > 0 &&
    !isRead(read, updatesKey)
  ) {
    rows.push({
      key: "updates",
      class: "update",
      title: updatesWaitingTitle(source.updates),
      detail: UPDATES_WAITING_DETAIL,
      action: { label: "Updates", onClick: source.onUpdates },
      readKey: updatesKey,
    });
  }

  // A file core marked as information: nothing to repair and nothing
  // missing, so it is a notice the person reads once.
  for (const warning of warnings) {
    if (isActionable(warning)) continue;
    const readKey = { id: `scan-note:${warning.path}`, identity: warning.path };
    if (isRead(read, readKey)) continue;
    rows.push({
      key: readKey.id,
      class: "notice",
      title: scanNoteTitle(warning),
      detail: `${warning.path} — ${scanNoteDetail(warning)}`,
      readKey,
    });
  }
  return rows;
}

/** The rows the Problems page holds: what the person must act on. */
export const problemsPageRows = (rows: AttentionRow[]): AttentionRow[] =>
  rows.filter((row) => row.class === "problem" || row.class === "decision");

/** The status footer's marker: one per item the Problems page holds, in
 *  the tone of the most severe. Null when nothing waits on the person. */
export function footerMarker(
  rows: AttentionRow[],
): { problems: number; decisions: number; tone: StatusTone } | null {
  const problems = rows.filter((row) => row.class === "problem").length;
  const decisions = rows.filter((row) => row.class === "decision").length;
  if (problems + decisions === 0) return null;
  return {
    problems,
    decisions,
    tone: problems > 0 ? CLASS_TONES.problem : CLASS_TONES.decision,
  };
}

function unreadableFileRow(
  warning: ScanWarning,
  onProblems: () => void,
): AttentionRow {
  return {
    key: `unreadable-file:${warning.path}`,
    class: "problem",
    title: unreadableFileTitle(warning),
    detail: unreadableFileDetail(warning),
    action: { label: SEE_PROBLEMS_LABEL, onClick: onProblems },
    card: { kind: "unreadable-file", warning },
  };
}
