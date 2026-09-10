import type {
  MarketplaceRow,
  Member_Deserialize as Member,
  Scope,
} from "@/bindings";
import type { OfferedRow } from "@/lib/install-ask";
import { sameScope } from "@/lib/scope";

/** What a template records for a package picked in a marketplace: the
 *  repository or folder the subscription points at, and the revision it
 *  reads at — not the alias.
 *
 *  An alias is a per-place manifest key and a template belongs to no
 *  place, so two projects spelling one marketplace differently would save
 *  as two different members. `null` where the subscription list has not
 *  answered for this row yet, which is a row that cannot be saved rather
 *  than one saved under a guess.
 *
 *  The revision comes off the same row as the repository, so a pinned
 *  subscription is saved pinned: read again later it could have moved, and
 *  what the template records is what the person had on screen. */
export function subscribedAt(
  rows: MarketplaceRow[],
  scope: Scope,
  source: string,
): { repo: string; rev: string | null } | null {
  const row = rows.find(
    (one) => one.name === source && sameScope(one.scope, scope),
  );
  const repo = row?.repo ?? row?.path ?? null;
  return repo === null ? null : { repo, rev: row?.rev ?? null };
}

/** What a ticked selection can be saved as: the members, and the rows it
 *  could not name.
 *
 *  A row whose marketplace nothing can name is not saved under a guess —
 *  a template records the repository, and a member with none resolves to
 *  nothing at install. The dropped rows come back rather than vanishing,
 *  so the surface can say which ones and why instead of reporting a
 *  count that is short. */
export interface Saveable {
  members: Member[];
  /** The rows left out, by the name they were ticked under. */
  dropped: string[];
}

export function membersFor(
  entries: OfferedRow[],
  rows: MarketplaceRow[],
): Saveable {
  const members: Member[] = [];
  const dropped: string[] = [];
  for (const entry of entries) {
    const at =
      entry.catalog.by === "subscription"
        ? subscribedAt(rows, entry.catalog.scope, entry.catalog.source)
        : null;
    if (at === null) {
      dropped.push(entry.row.name);
      continue;
    }
    members.push({
      kind: entry.row.kind,
      name: entry.row.name,
      enabled: true,
      source: { held: "marketplace", repo: at.repo, rev: at.rev },
    });
  }
  return { members, dropped };
}
