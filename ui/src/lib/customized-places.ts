// Customization is per place. A package installed at User level and in two
// projects can be changed in one of them and untouched in the others, so
// every mark the app draws is about one place — never about the package as
// a whole. Three facts make a place yours: the manifest overlay that
// place's Customize tab writes, files edited by hand there, and a fork,
// which is that place's own copy of the package. This joins them, and says
// how far a read got rather than guessing when a fact is not in hand.

import type { ItemKind, Scope, UpdateRow } from "@/bindings";
import { isCustomized, itemCustomization } from "@/lib/customization";
import type { Draft } from "@/lib/editor-draft";
import { sameScope, scopeKey } from "@/lib/scope";

/** What is known about one place's copy of a package. `unknown` is a real
 *  answer, not a default: a path or local source gets no update row, so
 *  nothing can say whether its files were edited by hand. `checking` is
 *  the answer while a read is still on its way — a place nobody has asked
 *  about yet has not been given up on. */
export type PlaceState = "customized" | "as-installed" | "checking" | "unknown";

/** Where a place's change is shown, and so where its mark leads. Settings
 *  live on the Customize tab. `files` is this place's own bytes — a hand
 *  edit, or a fork — and the overview is where both are: the notice
 *  offering the keep-or-discard decision for an edit, the Forked badge for
 *  a fork, whose decision is already made. */
export type PlaceChange = "files" | "settings";

export interface PlaceStanding {
  scope: Scope;
  state: PlaceState;
  /** What made it `customized`, or null when nothing did. */
  change: PlaceChange | null;
  /** This place's copy is a fork of what the catalog carries, read from
   *  that place's own manifest — the same table `package_meta` reads, so
   *  the fact never depends on an update check having succeeded. */
  forked: boolean;
}

/** How a read went. Two states cannot answer the question, and they are
 *  not the same answer: `pending` is still running and will land, `failed`
 *  came back with nothing and will not retry on its own. */
export type ReadState = "pending" | "ready" | "failed";

/** Everything the standings are read from, gathered once per screen. */
export interface PlacesSource {
  /** Each place's manifest as it stands on screen, keyed by scope. */
  manifests: Record<string, Draft>;
  /** Update rows keyed by {@link placeKey} — the per-place hand-edit fact,
   *  absent for the places the engine cannot speak about. */
  rows: Map<string, UpdateRow>;
  /** How the read of the update standing went; hand edits are known only
   *  once it is `ready`. */
  updatesRead: ReadState;
  /** How the read of every place's manifest went, so a manifest missing
   *  from {@link manifests} is told apart from one that has not been asked
   *  for yet. */
  manifestsRead: ReadState;
  /** Places whose last manifest read failed. Their manifest is still in
   *  {@link manifests} so a mark does not disappear, but it answers for an
   *  earlier moment — this join must not read it as current. */
  unreadPlaces: ReadonlySet<string>;
  /** A pass over every place's manifest is running. Distinct from
   *  {@link manifestsRead}, which stays `ready` once one has succeeded: a
   *  project registered afterwards has no manifest yet and its read is on
   *  its way, and calling that "not checked" names the wrong cause. */
  manifestsReading: boolean;
  /** A read of the update standing is running, of either kind, for the
   *  same reason. */
  updatesReading: boolean;
}

const placeKey = (kind: ItemKind, name: string, scope: Scope): string =>
  `${kind}:${name}:${scopeKey(scope)}`;

export function placeStandings(
  source: PlacesSource,
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): PlaceStanding[] {
  return scopes.map((scope) => {
    // A manifest kept from before a failed re-read is last-known, not
    // read. Taking it for current is the whole fault these marks exist to
    // avoid, one level down from the badge.
    const key = scopeKey(scope);
    const manifest = source.unreadPlaces.has(key)
      ? undefined
      : source.manifests[key];
    const row = source.rows.get(placeKey(kind, name, scope));
    // Null is "could not be read", which is why neither reads as false: a
    // manifest that failed to load and a place with no update row both
    // leave the question open.
    const overlay = manifest
      ? isCustomized(itemCustomization(manifest, kind, name))
      : null;
    const handEdited =
      source.updatesRead === "ready" ? (row?.blockedByLocalEdit ?? null) : null;
    // One fact, one source. The manifest answers when it was read — that is
    // what keeps a fork's badge through a failed update check. Where it was
    // not, the engine's row carries the same fact, read from the same file
    // by the side that also knows whether this place has a row at all: two
    // readers disagreeing is how a surface offers an action the engine has
    // already refused.
    // The fallback is only as good as the read it comes from: a row kept
    // from before a failed check answers for an earlier moment, and a fork
    // can have been discarded since. With the manifest unread and the
    // check unfinished, nobody can say — which is what `unknown` is for.
    const forked = manifest
      ? manifest.forks?.[kind]?.[name] != null
      : source.updatesRead === "ready" && row?.forked === true;
    // Ranked by which fact has something to land on. A hand edit comes
    // first: it is the one still waiting on a decision, and the notice
    // offering it is on the overview. Then an overlay, on the Customize
    // tab that wrote it. A fork last — it is the standing state of this
    // place rather than anything to act on, so it must never send someone
    // to the overview past instructions they typed on the other tab.
    const change: PlaceChange | null =
      handEdited === true
        ? "files"
        : overlay === true
          ? "settings"
          : forked
            ? "files"
            : null;
    // A read still on its way is not a read that came back empty: saying
    // "not checked" of a place nobody has asked about yet names the wrong
    // cause, and a read that failed is not still running.
    //
    // `pending` is the state before any read has come back, so it speaks
    // for every place at once and nothing here narrows it. A pass running
    // after one has succeeded is different: the facts it will bring are
    // already in hand for most places, and calling those "checking" every
    // time the window regains focus would blink the marks through a state
    // on their way back to themselves. So the in-flight signals count only
    // where this place has nothing yet — a project registered after the
    // first pass has neither manifest nor row, and its reads are running.
    const stillReading =
      (overlay === null &&
        (source.manifestsRead === "pending" || source.manifestsReading)) ||
      source.updatesRead === "pending" ||
      (row === undefined && source.updatesReading);
    const state: PlaceState =
      change != null
        ? "customized"
        : stillReading
          ? "checking"
          : overlay === null || handEdited === null
            ? "unknown"
            : "as-installed";
    return { scope, state, change, forked };
  });
}

export const customizedPlaces = (standings: PlaceStanding[]): Scope[] =>
  standings.filter((one) => one.state === "customized").map((one) => one.scope);

export const forkedPlaces = (standings: PlaceStanding[]): Scope[] =>
  standings.filter((one) => one.forked).map((one) => one.scope);

/** How many places a mark cannot speak for: reads that came back unable to
 *  say. A read still on its way is not one of them — every launch would
 *  otherwise open by calling places unchecked and then take it back. */
export const uncheckedPlaces = (standings: PlaceStanding[]): number =>
  standings.filter((one) => one.state === "unknown").length;

/** Whether anything on this screen is marked, without building the list to
 *  find out — the Library asks once per group to decide on its colour key. */
export const anyCustomized = (standings: PlaceStanding[]): boolean =>
  standings.some((one) => one.state === "customized");

/** This place's update row, from the index every screen already shares —
 *  so a page reading one fact off a row never scans the whole list again. */
export const rowIn = (
  source: PlacesSource,
  kind: ItemKind,
  name: string,
  scope: Scope,
): UpdateRow | null => source.rows.get(placeKey(kind, name, scope)) ?? null;

/** This place's row only when its files were edited by hand: the one fact
 *  that holds an update back and puts the keep-or-discard notice on screen.
 *  Any other row means neither. */
export const editedRowIn = (
  source: PlacesSource,
  kind: ItemKind,
  name: string,
  scope: Scope,
): UpdateRow | null => {
  const row = rowIn(source, kind, name, scope);
  return row?.blockedByLocalEdit ? row : null;
};

export const standingIn = (
  standings: PlaceStanding[],
  scope: Scope,
): PlaceStanding | null =>
  standings.find((one) => sameScope(one.scope, scope)) ?? null;

/** Every place's manifest as it stands on screen: saved everywhere, and the
 *  draft in hand for the one place being edited — so a chip, a row, and the
 *  header badge never disagree about the place you are typing in. */
export function manifestsOnScreen(
  saved: Record<string, Draft>,
  scope: Scope,
  draft: Draft | null,
): Record<string, Draft> {
  if (!draft) return saved;
  return { ...saved, [scopeKey(scope)]: draft };
}

export const indexRows = (rows: UpdateRow[]): Map<string, UpdateRow> =>
  new Map(rows.map((row) => [placeKey(row.kind, row.name, row.scope), row]));

/** A store's loaded/error pair as the one answer the join asks for. */
export const readState = (loaded: boolean, error: string | null): ReadState =>
  loaded ? "ready" : error ? "failed" : "pending";
