import type {
  Bookmark,
  BookmarkItem,
  Catalog,
  CatalogSummary,
  MarketplaceRow,
  Member_Deserialize as Member,
  SavedItem,
} from "@/bindings";
import { rowForCatalog, summaryFor } from "@/lib/marketplace-display";

/** What a surface needs to save, or to recognise, a marketplace item.
 *
 *  Two strings for one marketplace, because they answer different
 *  questions. `repo` is what a bookmark records — the repository or folder
 *  the subscription points at, never its alias, which is a per-place
 *  manifest key that a bookmark belonging to no place cannot use.
 *  `identity` is that reference folded to the one string every comparison
 *  in kendex makes, which is what tells a saved row from an unsaved one
 *  however either side spells the marketplace. */
export interface BookmarkTarget {
  repo: string;
  identity: string;
}

/** The marketplace a page or row is showing, in both spellings.
 *
 *  Both come from core: the subscription row carries the reference it
 *  declares and the identity core folded it to, and a repository browsed
 *  before anyone subscribes carries the same pair on the summary that
 *  fetched it. Neither is derived here — a second spelling of that fold
 *  outside core would be a second answer to which marketplaces are one.
 *
 *  `null` where neither read has landed yet, which is a surface that
 *  cannot yet say which marketplace it is showing rather than one that
 *  should guess. */
export function bookmarkTarget(
  catalog: Catalog,
  rows: MarketplaceRow[],
  summaries: Record<string, CatalogSummary>,
): BookmarkTarget | null {
  if (catalog.by === "repo") {
    const identity = summaryFor(summaries, catalog)?.repoIdentity ?? null;
    return identity === null ? null : { repo: catalog.repo, identity };
  }
  const row = rowForCatalog(rows, catalog);
  const repo = row?.repo ?? row?.path ?? null;
  const identity = row?.repoIdentity ?? null;
  return repo === null || identity === null ? null : { repo, identity };
}

/** Whether these name the same marketplace item. Kind and name are
 *  compared as they are stored; the marketplace is compared on the folded
 *  identity core handed both sides. */
export const sameItem = (held: BookmarkItem, wanted: BookmarkItem): boolean =>
  held.is === wanted.is &&
  (held.is !== "package" ||
    wanted.is !== "package" ||
    held.kind === wanted.kind);

/** The saved item matching this target, kind and name, or undefined. */
export const savedAs = (
  saved: SavedItem[],
  target: BookmarkTarget | null,
  item: BookmarkItem,
  name: string,
): SavedItem | undefined =>
  target === null
    ? undefined
    : saved.find(
        (one) =>
          one.repoIdentity === target.identity &&
          one.bookmark.name === name &&
          sameItem(one.bookmark.item, item),
      );

/** The bookmark a target, kind and name stand for. */
export const bookmarkOf = (
  target: BookmarkTarget,
  item: BookmarkItem,
  name: string,
): Bookmark => ({ repo: target.repo, item, name });

/** What a template records for a saved item: the marketplace the bookmark
 *  already holds, and the item's own kind and name.
 *
 *  A bookmark stores exactly what a template member needs — the repository
 *  rather than an alias — so nothing here looks a marketplace up. The
 *  revision is null because a bookmark pins none: it is a note about where
 *  something came from, not a version choice. */
export const memberOf = (saved: SavedItem): Member => ({
  kind:
    saved.bookmark.item.is === "bundle" ? "bundle" : saved.bookmark.item.kind,
  name: saved.bookmark.name,
  enabled: true,
  source: { held: "marketplace", repo: saved.bookmark.repo, rev: null },
});
