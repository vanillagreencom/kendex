import type { Catalog, MarketplaceMeta, MarketplaceRow } from "@/bindings";
import {
  LOCAL_FOLDER_LABEL,
  UNNAMED_MARKETPLACE,
} from "@/lib/copy-marketplaces";
import { catalogKey, marketKey } from "@/stores/marketplaces-shared";

/** What one marketplace is called and where it comes from, on every surface
 *  that names one: the card, the breadcrumb, the page header, the packages
 *  table's Marketplace column and the available package's From line. One
 *  answer, so those five cannot describe the same subscription two ways. */
export interface MarketplaceDisplay {
  /** The visible title. Never `.` or `..`: an alias is what the manifest
   *  keys the source under, and a relative one names nothing on screen. */
  name: string;
  /** Whether the catalogue is a folder on this machine rather than a remote
   *  repository. A local working checkout and the remote catalogue it was
   *  cloned from declare the same name, and this is what tells them apart. */
  local: boolean;
  /** Where it comes from, resolved: the repository as declared, or the
   *  folder's path on this machine. Empty where the declaration carries
   *  neither. */
  where: string;
  /** The alias the manifest declares it under — what `unsubscribe` and the
   *  engine address it by, and what source details show. */
  alias: string;
}

/** A path or reference's last segment, `/` or `\` separated: a folder's own
 *  name, or a repository's. Empty where the string ends in neither. */
const leaf = (of: string | null): string =>
  (of ?? "")
    .split(/[\\/]+/)
    .filter((part) => part !== "")
    .at(-1) ?? "";

/** Whether a string can stand alone as a title. `.` and `..` are relative
 *  path spellings: they name a folder only beside the base they are
 *  resolved against, which a title does not carry. */
const readable = (text: string): boolean => {
  const trimmed = text.trim();
  return trimmed !== "" && trimmed !== "." && trimmed !== "..";
};

/** What to call a catalogue, from whatever it has said about itself.
 *
 *  The catalogue's own declared name leads: `[marketplace] name` is what its
 *  author called it, and it is the same name however many places subscribe
 *  under however many aliases. Where the catalogue has not been read — or
 *  says nothing — the resolved folder or repository answers, because that is
 *  a name the reader can recognise on their own machine. The alias is last:
 *  `auto_alias` usually makes it the reference's last segment anyway, and a
 *  hand-written one can be `.`, which names nothing on screen. */
export function displayName({
  meta,
  resolvedPath,
  repo,
  alias,
}: {
  meta: MarketplaceMeta | null;
  resolvedPath: string | null;
  repo: string | null;
  alias: string;
}): string {
  const candidates = [
    meta?.name ?? "",
    leaf(resolvedPath),
    leaf(repo),
    alias,
    resolvedPath ?? "",
  ];
  return candidates.find(readable)?.trim() ?? UNNAMED_MARKETPLACE;
}

/** One subscription row's display identity. */
export function marketplaceDisplay(row: MarketplaceRow): MarketplaceDisplay {
  // A folder marketplace is the one with no repository behind it, whatever
  // it calls itself: `resolvedPath` is core's answer for the declaration,
  // and `repoIdentity` is core's answer for a remote on any host.
  const local = row.repo === null && row.repoIdentity === null;
  return {
    name: displayName({
      meta: row.meta,
      resolvedPath: row.resolvedPath,
      repo: row.repo,
      alias: row.name,
    }),
    local,
    // The resolved path, never the declared one: `.` is what the person
    // typed, and it reads as the app's own folder wherever it is shown.
    where: (local ? row.resolvedPath : row.repo) ?? row.resolvedPath ?? "",
    alias: row.name,
  };
}

/** Where a marketplace comes from, as one line: a folder says so, because a
 *  local working checkout and the remote catalogue it came from otherwise
 *  read as the same marketplace listed twice. */
export const sourceLine = (display: MarketplaceDisplay): string =>
  display.where === ""
    ? ""
    : display.local
      ? `${LOCAL_FOLDER_LABEL} · ${display.where}`
      : display.where;

/** The subscription row a catalog addresses, out of the live overview rows.
 *  Matched on the store's own subscription key rather than on the alias: an
 *  alias is unique inside one place's manifest and nowhere else, so the
 *  alias alone would match another place's subscription of the same name. */
export const rowForCatalog = (
  rows: MarketplaceRow[],
  catalog: Catalog,
): MarketplaceRow | undefined => {
  if (catalog.by !== "subscription") return undefined;
  const key = catalogKey(catalog);
  return rows.find((row) => marketKey(row.scope, row.name) === key);
};

/** What a catalog is called in a title or breadcrumb. A subscription is its
 *  row's display name, and a repository nobody subscribes to is the
 *  repository — there is no declaration to read a name off yet. */
export const catalogTitle = (
  rows: MarketplaceRow[],
  catalog: Catalog | undefined,
): string | null => {
  if (!catalog) return null;
  if (catalog.by === "repo") return catalog.repo;
  const row = rowForCatalog(rows, catalog);
  return row ? marketplaceDisplay(row).name : catalog.source;
};
