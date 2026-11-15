import type {
  MarketplaceRow,
  Member_Deserialize as Member,
  Scope,
} from "@/bindings";
import { commands } from "@/bindings";
import type { OfferedRow } from "@/lib/install-ask";
import { sameScope } from "@/lib/scope";

/** The observed subscription revision. Core resolves the selected Catalog
 *  against its declaration; this read only preserves the pin on screen. */
export function subscribedAt(
  rows: MarketplaceRow[],
  scope: Scope,
  source: string,
): { rev: string | null } | null {
  const row = rows.find(
    (one) => one.name === source && sameScope(one.scope, scope),
  );
  return row === undefined ? null : { rev: row.rev ?? null };
}

/** What a ticked selection can be saved as: the members, and the rows it
 *  could not name.
 *
 *  A subscription row that has not been read cannot supply its observed
 *  pin. Return its name so the dialog reports the omitted selection. */
export interface Saveable {
  members: Member[];
  /** The rows left out, by the name they were ticked under. */
  dropped: string[];
}

export async function membersFor(
  entries: OfferedRow[],
  rows: MarketplaceRow[],
): Promise<Saveable> {
  const members: Member[] = [];
  const dropped: string[] = [];
  for (const entry of entries) {
    const at =
      entry.catalog.by === "subscription"
        ? subscribedAt(rows, entry.catalog.scope, entry.catalog.source)
        : null;
    if (entry.catalog.by === "subscription" && at === null) {
      dropped.push(entry.row.name);
      continue;
    }
    const answer = await commands.templateCatalogSource(
      entry.catalog,
      at?.rev ?? null,
    );
    if (answer.status === "error") throw new Error(answer.error);
    members.push({
      kind: entry.row.kind,
      name: entry.row.name,
      enabled: true,
      source: answer.data,
    });
  }
  return { members, dropped };
}
