import type {
  Catalog,
  CatalogSummary,
  DirectoryRow,
  MarketplaceMeta,
  MarketplaceRow,
} from "@/bindings";
import {
  LOCAL_FOLDER_LABEL,
  UNNAMED_MARKETPLACE,
} from "@/lib/copy-marketplaces";
import {
  catalogKey,
  marketKey,
  subscription,
} from "@/stores/marketplaces-shared";

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
  listedName,
  resolvedPath,
  repo,
  alias,
}: {
  meta: MarketplaceMeta | null;
  /** What a directory listed this repository under, where a page was opened
   *  from one. Below the catalogue's own name and above the address: the
   *  issue's rule is the declared name first, and a listing that outranked
   *  it would title a subscribed repository by its directory label on the
   *  page while its card and crumb read the catalogue's own. */
  listedName?: string | null;
  resolvedPath: string | null;
  repo: string | null;
  alias: string;
}): string {
  const candidates = [
    meta?.name ?? "",
    listedName ?? "",
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

/** What one page knows about the catalog it is showing, from whichever
 *  reads have landed. */
export interface CatalogFacts {
  catalog: Catalog;
  /** The subscription declaring it, where a place does. */
  row?: MarketplaceRow | null;
  /** The catalog's own account of itself, once it has been fetched. */
  summary?: CatalogSummary | null;
  /** What a directory listed this repository under, where the page was
   *  opened from one — [listedNameOf] over the community rows. It answers
   *  below the catalogue's own declared name and above the address. */
  listedName?: string | null;
}

/** One catalog's display identity, for the marketplace page's own header,
 *  the breadcrumb above it, the cross-marketplace table's column and the
 *  available package's From block — which all name the same marketplace and
 *  must not name it four ways.
 *
 *  Everything the page knows is folded in, in the order it is worth
 *  believing: the subscription's own declaration, then what the catalog
 *  said when it was fetched, then the directory's listing. The address is
 *  the last resort and goes through [displayName] like every other
 *  candidate — an alias reaching a title unfiltered is what put a bare `.`
 *  on the page this module exists to fix, and a page draws its breadcrumb
 *  before the overview read lands and after one fails. */
export const displayFor = ({
  catalog,
  row,
  summary,
  listedName,
}: CatalogFacts): MarketplaceDisplay => {
  // A row's own declaration answers where it can. A summary is the same
  // catalog read fresh, so it fills in for a page whose subscription rows
  // have not arrived, and adds nothing where they have.
  const meta = row?.meta ?? summary?.meta ?? null;
  const repo =
    row?.repo ??
    (catalog.by === "repo" ? catalog.repo : summary?.provenance) ??
    null;
  const alias = catalog.by === "repo" ? catalog.repo : catalog.source;
  const local = row ? row.repo === null && row.repoIdentity === null : false;
  return {
    name: displayName({
      meta,
      listedName,
      resolvedPath: row?.resolvedPath ?? null,
      repo,
      alias,
    }),
    local,
    where: (local ? row?.resolvedPath : repo) ?? row?.resolvedPath ?? "",
    alias,
  };
};

/** What a browsed repository has turned out to be: the subscription its
 *  fetched summary names, where this machine already declares it. Spelled
 *  once, because two readers derive it — the page, which carries on as that
 *  subscription, and any surface resolving a name from the address the page
 *  was opened by. A repository nobody declares stays itself.
 *
 *  It is what makes a directory's label stop applying: a subscription is
 *  never a directory row, and a label that outlived the conversion would
 *  title the page and its crumb by a stranger's name for the repository
 *  while the card beside them read what the subscription resolves to. */
export const discoveredCatalog = (
  catalog: Catalog,
  summary: CatalogSummary | null,
): Catalog =>
  catalog.by === "repo" && summary?.subscription
    ? subscription(summary.subscription.scope, summary.subscription.source)
    : catalog;

/** What a directory lists a repository under, for the page showing it and
 *  the breadcrumb over that page. Spelled once, so a title and the crumb
 *  above it cannot be resolved from different inputs: a subscription is
 *  never a directory row, so a page carried on as one reads its
 *  catalogue's own name in both places. */
export const listedNameOf = (
  rows: DirectoryRow[] | undefined,
  catalog: Catalog,
): string | null =>
  catalog.by === "repo"
    ? (rows?.find((row) => row.repo === catalog.repo)?.name ?? null)
    : null;

/** The same answer for a surface holding only a catalog and the store's own
 *  slices — it finds the declaring row and the fetched summary itself. A
 *  page already holding either passes them to [displayFor] instead: its
 *  props are fresher than a lookup, and a header re-deriving what it was
 *  handed is how a header and its breadcrumb drift apart. */
export const catalogDisplay = (
  rows: MarketplaceRow[],
  summaries: Record<string, CatalogSummary>,
  catalog: Catalog,
  directory?: DirectoryRow[],
): MarketplaceDisplay => {
  // The summary stays under the key the page was opened by; the catalog it
  // discovered is what the page has become. Both halves, here, so a crumb
  // resolving from the address alone reaches the same marketplace the page
  // and the card do.
  const summary = summaries[catalogKey(catalog)] ?? null;
  const declared = discoveredCatalog(catalog, summary);
  return displayFor({
    catalog: declared,
    row: rowForCatalog(rows, declared),
    summary,
    listedName: listedNameOf(directory, declared),
  });
};

/** What a catalog is called in a title or breadcrumb. */
export const catalogTitle = (
  rows: MarketplaceRow[],
  summaries: Record<string, CatalogSummary>,
  catalog: Catalog | undefined,
  directory?: DirectoryRow[],
): string | null =>
  catalog ? catalogDisplay(rows, summaries, catalog, directory).name : null;
