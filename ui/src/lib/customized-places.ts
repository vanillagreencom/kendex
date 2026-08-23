import type { ItemKind, Scope, UpdateRow } from "@/bindings";
import { customizedItems } from "@/lib/customization";
import type { Draft } from "@/lib/editor-draft";
import { scopeKey } from "@/lib/scope";

/** What one place holds for one package.
 *
 *  Three answers, not two. A place whose manifest was read and holds
 *  nothing is not the same as a place nobody could read: the first is
 *  "yours is the stock copy", the second is "nobody knows", and printing
 *  the first over the second is the badge lying in a new way. */
export type Standing = "customized" | "stock" | "unknown";

/** Why a place counts as customized, which decides where a click lands. */
export type Why = "settings" | "edited" | "forked";

export interface PlaceStanding {
  scope: Scope;
  standing: Standing;
  why: Why | null;
}

/** Everything the standings are read from, gathered once per screen. */
export interface PlacesSource {
  /** Each place's saved manifest, keyed by scope. A place absent here has
   *  not been read — which is the whole reason this is a record and not a
   *  list of the customized ones. */
  manifests: Record<string, Draft>;
  /** Update rows keyed by {@link placeKey}: the per-place hand-edit and
   *  fork facts, absent for places the engine cannot speak about. */
  rows: Map<string, UpdateRow>;
  /** Whether the update read has landed. Hand edits are known only after
   *  it has; before, a place with no row is unread rather than clean. */
  updatesLoaded: boolean;
  /** {@link indexCustomized} over {@link manifests}, built once. */
  settings: ReadonlySet<string>;
}

const placeKey = (kind: ItemKind, name: string, scope: Scope): string =>
  `${kind}:${name}:${scopeKey(scope)}`;

export function indexRows(rows: UpdateRow[]): Map<string, UpdateRow> {
  const out = new Map<string, UpdateRow>();
  for (const row of rows) out.set(placeKey(row.kind, row.name, row.scope), row);
  return out;
}

/** Every package each place holds something for, keyed by place and
 *  package.
 *
 *  Built once per screen rather than per row: `customizedItems` walks a
 *  whole manifest, and asking it per package per place walks every
 *  manifest again for every row on the Library. */
export function indexCustomized(
  manifests: Record<string, Draft>,
): ReadonlySet<string> {
  const keys = new Set<string>();
  for (const [where, manifest] of Object.entries(manifests))
    for (const item of customizedItems(manifest))
      keys.add(`${where}|${item.kind}:${item.name}`);
  return keys;
}

/** How each place stands, in the order the scopes were given.
 *
 *  One word, three sources: what the person set on the Customize tab, what
 *  they edited in the installed files, and whether the copy is their own
 *  fork. Any of them makes the place theirs — the badge answers "is this
 *  place mine", and all three are ways of saying yes. */
export function placeStandings(
  source: PlacesSource,
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): PlaceStanding[] {
  return scopes.map((scope) => {
    const manifest = source.manifests[scopeKey(scope)];
    const row = source.rows.get(placeKey(kind, name, scope));
    // Two readers of one fact, and either saying yes is a yes. Preferring
    // the manifest outright loses a fork this app has just made: the row
    // is re-read with the write and the saved manifest is not, so the mark
    // goes missing at the one moment the reader is certain it is theirs.
    // The cost of taking either is a mark that outlives a discard until the
    // next read — the mark being late rather than the mark being missing.
    const inManifest = manifest ? manifest.forks?.[kind]?.[name] != null : null;
    const inRow = source.updatesLoaded && row ? row.forked : null;
    const forked =
      inManifest || inRow
        ? true
        : inManifest === null && inRow === null
          ? null
          : false;
    const settings = manifest
      ? source.settings.has(`${scopeKey(scope)}|${kind}:${name}`)
      : null;
    // A place with no row after the read has landed is one the engine
    // cannot speak about — a local source has no version to compare
    // against — so its hand-edit state stays unknown rather than false.
    const edited = source.updatesLoaded && row ? row.blockedByLocalEdit : null;
    if (forked) return { scope, standing: "customized", why: "forked" };
    if (settings) return { scope, standing: "customized", why: "settings" };
    if (edited) return { scope, standing: "customized", why: "edited" };
    // Every source has to have spoken before a place can be called stock.
    // One silent source is enough to leave the question open: the mark
    // that is missing is indistinguishable from the mark that is false.
    if (settings === null || edited === null || forked === null)
      return { scope, standing: "unknown", why: null };
    return { scope, standing: "stock", why: null };
  });
}

export function standingIn(
  standings: PlaceStanding[],
  scope: Scope,
): PlaceStanding | undefined {
  const key = scopeKey(scope);
  return standings.find((s) => scopeKey(s.scope) === key);
}
