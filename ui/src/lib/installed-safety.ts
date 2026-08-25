// One installed package's advisory reading, out of the per-tool rows the
// audit returns.
//
// kendex renders the same bytes at every tool's place, so a skill installed
// for five tools comes back as five rows of one reading. A person counts the
// thing, not the renderings — the same rule `lib/drift-merge.ts` follows for
// drift rows.
import type { AuditResult, AuditView, ItemKind, Scope } from "@/bindings";
import { sameScope } from "@/lib/scope";

/** The reading for one package, or null where the audit has no row for it —
 *  it has not answered yet, or the package is not installed where asked.
 *
 *  Where the rows disagree, the lowest score stands and every finding is
 *  kept: two tools reading different bytes under one name is a real state,
 *  and the worse of the two is the one worth showing. Findings alike in
 *  rule, place and message are one finding seen twice. */
export function installedSafety(
  views: AuditView[],
  kind: ItemKind,
  name: string,
  /** One place, or every place the package sits when left out — the
   *  Updates page's rows are per package, not per place. */
  scope?: Scope,
): AuditResult | null {
  const rows = views
    .filter((view) => scope === undefined || sameScope(view.scope, scope))
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
    findings: dedupe(
      rows.flatMap((row) => row.findings),
      (finding) =>
        `${finding.rule}:${finding.severity}:${finding.location}:${finding.message}`,
    ),
    skipped: dedupe(
      rows.flatMap((row) => row.skipped),
      (skip) => `${skip.rule}:${skip.reason}`,
    ),
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
