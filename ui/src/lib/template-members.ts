import type {
  MarketplaceRow,
  Member_Deserialize as Member,
  Scope,
} from "@/bindings";
import type { OfferedRow } from "@/lib/install-ask";
import { sameScope } from "@/lib/scope";

/** What a template records for a package picked in a marketplace: the
 *  repository or folder the subscription points at, not the alias.
 *
 *  An alias is a per-place manifest key and a template belongs to no
 *  place, so two projects spelling one marketplace differently would save
 *  as two different members. `null` where the subscription list has not
 *  answered for this row yet, which is a row that cannot be saved rather
 *  than one saved under a guess. */
export function repoOf(
  rows: MarketplaceRow[],
  scope: Scope,
  source: string,
): string | null {
  const row = rows.find(
    (one) => one.name === source && sameScope(one.scope, scope),
  );
  return row?.repo ?? row?.path ?? null;
}

/** The ticked rows as template members. A row whose marketplace nothing
 *  can name is left out rather than saved under a name a later install
 *  would not resolve. */
export function membersFor(
  entries: OfferedRow[],
  rows: MarketplaceRow[],
): Member[] {
  const members: Member[] = [];
  for (const entry of entries) {
    if (entry.catalog.by !== "subscription") continue;
    const repo = repoOf(rows, entry.catalog.scope, entry.catalog.source);
    if (repo === null) continue;
    members.push({
      kind: entry.row.kind,
      name: entry.row.name,
      enabled: true,
      source: { held: "marketplace", repo, rev: null },
    });
  }
  return members;
}
