// One marketplace, however many places declare it. The Subscribed tab used
// to list a row per (place, marketplace), so a catalog subscribed
// everywhere appeared once per project with nothing saying the three rows
// were the same catalog. Grouping is the whole difference: the card is the
// marketplace, and the places it is subscribed in are a fact about it.
import type { MarketplaceRow } from "@/bindings";
import { scopeLabel } from "@/lib/derive";
import { scopeNames } from "@/lib/labels";

export interface SubscribedMarketplace {
  /** What [marketplaceIdentity] returned for every place in this group. */
  key: string;
  /** What to call it — the alias the place a card opens uses. */
  name: string;
  /** The repository or folder behind it, for the card's second line. */
  where: string;
  /** Every place that declares it, personal first. */
  places: MarketplaceRow[];
  /** The subscription a card opens: an enabled place before a switched-off
   * one, personal before a project, so the page opens on the declaration
   * that is actually offering packages. */
  open: MarketplaceRow;
  /** What [open] offers — null until that place's catalog has been read,
   * whatever a sibling place has fetched. */
  packages: number | null;
}

/** What makes two declarations the same marketplace, spelled once for
 * every surface that folds them: the card grid, the Projects section, and
 * the page that asks the section which marketplace it is looking at.
 *
 * `repoIdentity` is core's `source_ref::repo_identity` — one string per
 * repository on any host, the same value subscription dedup and update
 * grouping compare. It is not `repoKey`, which is the GitHub `owner/repo`
 * and is null everywhere else: keying on that left every GitLab or
 * self-hosted remote falling through to the alias, and an alias is
 * per-declaration. `auto_alias` takes the reference's last path segment and
 * uniquifies it only inside one scope's manifest, so a personal
 * `gitlab.com/acme/kit` and a project's `git.internal/tools/kit` both
 * become `kit` — two unrelated marketplaces in one card, with the Projects
 * section aiming its switch and its Unsubscribe at the wrong subscription.
 *
 * A local folder has no repository, so its path is the identity — but only
 * an absolute one names the same directory from every place. `row.path` is
 * the declaration verbatim, and `source::path_root` resolves a relative one
 * against each scope's own root: `env.home` personally, the project root in
 * a project. So `./catalog` is three different folders across three places
 * under one string, and the scope has to be part of the key. Absolute paths
 * stay shared, because two places naming `/srv/catalog` really are looking
 * at one catalog.
 *
 * That holds for a path spelled in the running platform's own shape, and
 * only there: this reads rootedness from the string, accepting both
 * platforms' shapes, while `path_root` asks `Path::is_absolute`, which
 * answers for one. On Unix `C:/catalog` is re-rooted per scope and keyed
 * here as one folder; a POSIX-rooted path on Windows mirrors it. Core
 * shipping the resolved path closes that, and is filed as KEN-1142.
 *
 * The alias is the last resort for a declaration carrying neither. It
 * usually over-splits, which is harmless — but two scopes declaring such a
 * source under one alias share `row.name`, so it can under-split too;
 * `list_subscriptions` emits those rows rather than skipping them, though
 * they resolve to nothing and offer no packages. */
export const marketplaceIdentity = (row: MarketplaceRow): string => {
  if (row.repoIdentity) return row.repoIdentity;
  if (row.path)
    return absolutePath(row.path)
      ? row.path
      : `${scopeLabel(row.scope)}:${row.path}`;
  return row.name;
};

/** A path spelled as rooted: POSIX-rooted, a Windows drive, or a UNC share.
 * Everything else — `./x`, `~/x`, `x/y` — is resolved against the reading
 * scope's own root. Both platforms' shapes are accepted here, so this
 * answers what a path is spelled as, not what the running platform will
 * treat it as; the block above says what that costs. */
const absolutePath = (path: string): boolean =>
  path.startsWith("/") ||
  /^[a-zA-Z]:[\\/]/.test(path) ||
  path.startsWith("\\\\");

/** Personal leads, then projects in the order the overview listed them.
 * Total, so a sort cannot be handed -1 for both (a,b) and (b,a): shared
 * with the Projects section, which sorts the same rows. */
export const personalFirst = (a: MarketplaceRow, b: MarketplaceRow): number =>
  Number(b.scope.scope === "global") - Number(a.scope.scope === "global");

/** Which place a marketplace opens as. One rule for the card that names it
 * and the page that redirects to it: a place actually offering packages
 * before a switched-off one, and — the sort having run first — personal
 * before a project. A redirect that ignored `enabled` would land a reader
 * on a page badged "Switched off here" over packages nothing installs,
 * which is the state this rule exists to avoid. */
export const openPlace = (
  places: MarketplaceRow[],
): MarketplaceRow | undefined => places.find((row) => row.enabled) ?? places[0];

const offered = (row: MarketplaceRow): number | null =>
  row.counts
    ? Object.values(row.counts).reduce((sum, count) => sum + count, 0)
    : null;

/** Every subscribed marketplace, once, with the places holding it. */
export function groupByMarketplace(
  rows: MarketplaceRow[],
): SubscribedMarketplace[] {
  const groups = new Map<string, MarketplaceRow[]>();
  for (const row of rows) {
    const key = marketplaceIdentity(row);
    const held = groups.get(key);
    if (held) held.push(row);
    else groups.set(key, [row]);
  }
  return [...groups.entries()]
    .map(([key, held]) => {
      const places = [...held].sort(personalFirst);
      // A group always holds at least the row that created it.
      const open = openPlace(places) as MarketplaceRow;
      return {
        key,
        name: open.name,
        where: open.repo ?? open.path ?? "",
        places,
        open,
        // From `open`, like every other field on the card. Taking the
        // first place that had fetched anything meant a card could name
        // one subscription, show its revision and open its page while
        // reporting another's count — and scopes can pin the same
        // repository to different revisions, so the number was sometimes
        // genuinely someone else's.
        //
        // The cost is deliberate: a card whose open place has not fetched
        // now reads "Not fetched yet" even where a sibling place has. That
        // is the honest answer, because the card describes the destination
        // it takes you to rather than the best number available anywhere
        // in the group.
        packages: offered(open),
      };
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** The places a marketplace is subscribed in, named — and told apart. Two
 * registered projects can end in the same folder, and a card listing
 * "kendex, kendex" names neither; where a basename is shared, the places
 * holding it carry their full path instead. The collision set is this
 * card's own places, which is what the line is drawing. */
export const placeNames = (group: SubscribedMarketplace): string[] =>
  scopeNames(group.places.map((row) => row.scope));

/** Whether two rows describe the same place, for the Projects section's
 * keys — the same spelling `scopeLabel` gives everywhere else. */
export const placeKey = (row: MarketplaceRow): string =>
  `${scopeLabel(row.scope)}:${row.name}`;
