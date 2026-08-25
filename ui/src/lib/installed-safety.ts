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
import { sameScope } from "@/lib/scope";

/** What makes two findings the same finding. The severity is in it because
 *  one rule can fire at different weights, and the message because one rule
 *  can match twice at one address for different reasons. Used both to fold
 *  repeats out of a reading and to key the lines rendered from it, so a
 *  screen never shows two rows a reader cannot tell apart. */
export const findingKey = (finding: Finding): string =>
  `${finding.rule}:${finding.severity}:${finding.location}:${finding.message}`;

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
 *  another is a number nothing on screen accounts for. */
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
    (lowest, row) =>
      lowest === null || row.safety.score < lowest.safety.score ? row : lowest,
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

function dedupe<T>(rows: T[], key: (row: T) => string): T[] {
  const seen = new Set<string>();
  return rows.filter((row) => {
    const id = key(row);
    if (seen.has(id)) return false;
    seen.add(id);
    return true;
  });
}
