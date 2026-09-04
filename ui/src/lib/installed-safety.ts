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
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): AuditResult | null {
  const rows = views
    .filter((view) => scopes.some((scope) => sameScope(view.scope, scope)))
    .flatMap((view) => view.safety)
    .filter((row) => row.kind === kind && row.name === name);
  const worst = rows.reduce<(typeof rows)[number] | null>(
    (lowest, row) => (lowest === null || worseThan(row, lowest) ? row : lowest),
    null,
  );
  if (worst === null) return null;
  return {
    safety: worst.safety,
    quality: worst.quality,
    ruleset: worst.ruleset,
    findings: dedupe(worst.findings, findingKey),
    skipped: dedupe(worst.skipped, (skip) => `${skip.rule}:${skip.reason}`),
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
