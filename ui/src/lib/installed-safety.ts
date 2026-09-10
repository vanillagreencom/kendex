// One installed package's advisory reading, out of the per-tool rows the
// audit returns.
//
// kendex renders the same bytes at every tool's place, so a skill installed
// for five tools comes back as five rows of one reading. A person counts the
// thing, not the renderings — the same rule `lib/drift-merge.ts` follows for
// drift rows.
import type {
  AuditResult,
  AuditView,
  Finding,
  ItemKind,
  Scope,
} from "@/bindings";
import { worstSeverityRank } from "@/lib/copy-safety";
import { sameScope } from "@/lib/scope";

/** What makes two findings the same finding. The severity is in it because
 *  one rule can fire at different weights, the message because one rule can
 *  match twice at one address for different reasons, and the line because
 *  one rule fires at many lines of one file, and leaving it out folds real
 *  defects away. Used both to fold repeats out of a reading and to key the
 *  lines rendered from it, so a screen never shows two rows a reader cannot
 *  tell apart, and never one row where there are two. */
export const findingKey = (finding: Finding): string =>
  `${finding.rule}:${finding.severity}:${finding.location}:${finding.line}:${finding.message}`;

/** A reading, and the place whose copy earned it. The scope travels with
 *  the reading because a reading over several places is one place's: a
 *  surface that shows the number and offers a way to what is behind it must
 *  send the reader to that same place, not to whichever the backend listed
 *  first. */
export interface InstalledSafety extends AuditResult {
  scope: Scope;
}

/** The reading for one package at the places asked about, or null where the
 *  audit has no row for it — it has not answered yet, or the package is not
 *  installed at any of them.
 *
 *  Always the places the caller names. A package's row on the Updates page
 *  is about the places that row lists, and a same-named package from an
 *  unrelated catalog somewhere else on the machine is a different package.
 *
 *  Where the rows disagree, one whole row wins: the lowest score, with the
 *  findings that earned it. Two tools reading different bytes under one name
 *  is a real state, and the worse of the two is the one worth showing — but
 *  it is shown entire, because a score from one reading over findings from
 *  another is a number nothing on screen accounts for.
 *
 *  Two rows can score the same and still not be equally bad: the score is
 *  100 less what the findings cost, so one critical costs what a handful of
 *  lighter hits do, and every reading at the floor scores 0 whatever put it
 *  there. Severity breaks the tie, or the row the backend happened to
 *  return first would decide which findings a reader ever sees. */
export function installedSafety(
  views: AuditView[],
  /** Null asks nothing: the audit answers by scope, kind and name, which
   *  a same-named recorded package shares, so a caller with no declaration
   *  behind it has nothing to look up. */
  kind: ItemKind | null,
  name: string,
  scopes: Scope[],
): InstalledSafety | null {
  if (kind === null) return null;
  // The place is the view's, not the row's: the view is what was matched
  // against the places asked about, so it is the place this reading answers
  // for.
  const rows = views
    .filter((view) => scopes.some((scope) => sameScope(view.scope, scope)))
    .flatMap((view) =>
      view.safety
        .filter((row) => row.kind === kind && row.name === name)
        .map((row) => ({ row, scope: view.scope })),
    );
  const worst = rows.reduce<(typeof rows)[number] | null>(
    (lowest, each) =>
      lowest === null || worseThan(each.row, lowest.row) ? each : lowest,
    null,
  );
  if (worst === null) return null;
  return {
    scope: worst.scope,
    safety: worst.row.safety,
    quality: worst.row.quality,
    ruleset: worst.row.ruleset,
    findings: dedupe(worst.row.findings, findingKey),
    skipped: dedupe(worst.row.skipped, (skip) => `${skip.rule}:${skip.reason}`),
  };
}

/** Lower score first, and on a tie the harsher finding. Strictly worse, so
 *  two rows that match on both leave the earlier one standing. */
function worseThan(
  row: { safety: { score: number }; findings: Finding[] },
  standing: { safety: { score: number }; findings: Finding[] },
): boolean {
  if (row.safety.score !== standing.safety.score) {
    return row.safety.score < standing.safety.score;
  }
  return worstSeverityRank(row.findings) > worstSeverityRank(standing.findings);
}

function dedupe<T>(rows: T[], key: (row: T) => string): T[] {
  const seen = new Set<string>();
  return rows.filter((row) => {
    const id = key(row);
    if (seen.has(id)) return false;
    seen.add(id);
    return true;
  });
}

/** What a safety score is showing, and the place it is showing it for.
 *
 *  One value rather than a reading, a failure and a place derived apart:
 *  every surface that draws a score also offers a way to what is behind it,
 *  and three fields computed separately can pair a current number with
 *  another place's failure, or words about one place with a link to
 *  another. Here the state and its place are decided together, once, from
 *  the audit state as it actually stands.
 *
 *  `at` is the place the words are true of, or null where they are true of
 *  no single place — nothing has answered, or the audit failed as a whole.
 *  A caller with a place of its own falls back to that. */
export type SafetyStanding =
  /** Nothing has answered yet, and nothing has failed. */
  | { state: "waiting"; at: null }
  /** The audit answered and had nothing to say about this package. */
  | { state: "unscored"; at: null }
  /** A reading the last check took. */
  | { state: "read"; at: Scope; result: InstalledSafety }
  /** A reading, and the check after it failed for that same copy: the
   *  number stays, and stops being what the files say now. */
  | { state: "stale"; at: Scope; result: InstalledSafety; why: string }
  /** No reading, because the read of that place failed. */
  | { state: "failed"; at: Scope; why: string }
  /** A failure that belongs to the audit as a whole and names no place. */
  | { state: "unavailable"; at: null; why: string };

/** The standing for one package at the places asked about, out of the audit
 *  state as it stands: its views, whether the last read failed as a whole,
 *  and whether any read has answered.
 *
 *  A failed read keeps the views it had, so a place that failed before it is
 *  still among them. That is why the whole audit's failure is decided first:
 *  it names no place, and a kept view's would send a reader somewhere the
 *  words on screen are not about. Below it, only a failure about the copy
 *  the reading is of qualifies that reading — another place failing leaves
 *  this number current and says its piece on its own row. */
export function safetyStanding(
  views: AuditView[],
  auditFailure: string | null,
  answered: boolean,
  /** Null asks nothing, per [installedSafety]: with no declaration behind
   *  the caller there is no row to look up, so the standing is whatever the
   *  audit's own state says and never another package's reading. */
  kind: ItemKind | null,
  name: string,
  scopes: Scope[],
): SafetyStanding {
  const result = installedSafety(views, kind, name, scopes);
  if (auditFailure !== null) {
    return result
      ? { state: "stale", at: result.scope, result, why: auditFailure }
      : { state: "unavailable", at: null, why: auditFailure };
  }
  const unreadable = views.find(
    (view) =>
      view.error && scopes.some((scope) => sameScope(view.scope, scope)),
  );
  const why = unreadable?.error?.message ?? null;
  if (result) {
    return unreadable &&
      why !== null &&
      sameScope(unreadable.scope, result.scope)
      ? { state: "stale", at: result.scope, result, why }
      : { state: "read", at: result.scope, result };
  }
  if (unreadable && why !== null) {
    return { state: "failed", at: unreadable.scope, why };
  }
  return answered
    ? { state: "unscored", at: null }
    : { state: "waiting", at: null };
}
