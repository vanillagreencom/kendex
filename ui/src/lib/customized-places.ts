import type {
  ItemKind,
  Scope,
  ScopeSettings,
  SettingsEdit,
  UpdateRow,
} from "@/bindings";
import {
  customizedItems,
  type ItemCustomization,
  itemCustomization,
} from "@/lib/customization";
import type { Draft } from "@/lib/editor-draft";
import { sameScope, scopeKey } from "@/lib/scope";
import { settingsValues } from "@/lib/settings-rows";

/** Why a place counts as customized, which decides where a click lands.
 *  `settings` is the manifest's overlay on the package; `values` is a
 *  package setting whose value in this place's settings file is not the
 *  package default. */
export type Why = "settings" | "values" | "edited" | "forked";

/** What one place holds for one package.
 *
 *  Three answers, not two. A place whose manifest was read and holds
 *  nothing is not the same as a place nobody could read: the first is
 *  "yours is the stock copy", the second is "nobody knows", and printing
 *  the first over the second is the badge lying in a new way. A
 *  customized place always says why; the other two never do. */
export type PlaceStanding =
  | { scope: Scope; standing: "customized"; why: Why }
  | { scope: Scope; standing: "stock" | "unknown"; why: null };

/** Everything the standings are read from, gathered once per screen.
 *  Built through {@link placesSource}, never by hand: {@link settings} is
 *  an index over {@link manifests}, and the two must not drift apart. */
interface PlacesSource {
  /** Each place's manifest, keyed by scope. A place absent here has not
   *  been read — which is the whole reason this is a record and not a
   *  list of the customized ones. */
  manifests: Record<string, Draft>;
  /** Update rows keyed by place and package: the per-place hand-edit and
   *  fork facts, absent for places the engine cannot speak about. */
  rows: Map<string, UpdateRow>;
  /** Whether the update read has landed. Hand edits are known only after
   *  it has; before, a place with no row is unread rather than clean. */
  updatesLoaded: boolean;
  /** Every package each place's manifest holds settings for, keyed
   *  `scope|kind:name`. Built once: `customizedItems` walks a whole
   *  manifest, and asking it per package per place walks every manifest
   *  again for every row on the Library. */
  settings: ReadonlySet<string>;
  /** Where each place's skills stand against their package defaults, by
   *  scope and by skill. A place absent here has not been read, and a
   *  skill answering null is one nothing can tell about — both are a
   *  third answer rather than a no, the same reason `manifests` is a
   *  record. */
  values: ReadonlyMap<string, ReadonlyMap<string, boolean | null>>;
}

const placeKey = (kind: ItemKind, name: string, scope: Scope): string =>
  `${kind}:${name}:${scopeKey(scope)}`;

export function placesSource(
  manifests: Record<string, Draft>,
  rows: UpdateRow[],
  updatesLoaded: boolean,
  settingsReads: Record<string, ScopeSettings>,
  /** Unsaved settings edits by place, from the surface editing one.
   *  The Library and the package header pass none: their manifest half
   *  reads the saved manifest too, and a draft counting on one half of
   *  a surface and not the other is the mismatch this answers. */
  settingsEdits: Record<string, SettingsEdit[]> = {},
): PlacesSource {
  const byPlace = new Map<string, UpdateRow>();
  for (const row of rows)
    byPlace.set(placeKey(row.kind, row.name, row.scope), row);
  const settings = new Set<string>();
  for (const [where, manifest] of Object.entries(manifests))
    for (const item of customizedItems(manifest))
      settings.add(`${where}|${item.kind}:${item.name}`);
  return {
    manifests,
    rows: byPlace,
    updatesLoaded,
    settings,
    values: settingsValues(settingsReads, settingsEdits),
  };
}

/** The manifests a page editing one place reads: its open draft in place
 *  of that place's saved manifest, so a setting removed and not yet saved
 *  leaves the index at once, as the Remove control promises, and one
 *  typed on a package's own page joins it. */
export function manifestsForEditing(
  saved: Record<string, Draft>,
  draft: Draft | null,
  scope: Scope,
): Record<string, Draft> {
  return draft ? { ...saved, [scopeKey(scope)]: draft } : saved;
}

/** The three facts about one package at one place, each null when nobody
 *  can say. Null is a real answer: a manifest that was not read and a
 *  place with no update row both leave the question open, and reading
 *  either as false is the mark lying in a new way. */
interface PlaceFacts {
  forked: boolean | null;
  settings: boolean | null;
  edited: boolean | null;
  /** A package setting whose value here is not the package default.
   *  Only skills ship settings, so every other kind is false once the
   *  place has been read — and null before it has. */
  values: boolean | null;
}

export function placeFacts(
  source: PlacesSource,
  kind: ItemKind,
  name: string,
  scope: Scope,
): PlaceFacts {
  const manifest = source.manifests[scopeKey(scope)];
  const row = source.rows.get(placeKey(kind, name, scope));
  // Two readers of the fork fact, and either saying yes is a yes.
  // Preferring the manifest outright loses a fork this app has just made:
  // the row is re-read with the write and the saved manifest is not, so
  // the mark goes missing at the one moment the reader is certain it is
  // theirs. The cost of taking either is a mark that outlives a discard
  // until the next read — the mark being late rather than missing.
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
  // A place that was read answers for every skill it installs; a kind
  // that ships no settings, and a skill this place does not install,
  // have nothing there to differ.
  const answers = source.values.get(scopeKey(scope));
  const answer = kind === "skill" ? answers?.get(name) : false;
  // Absent is a skill this place does not install, and there is nothing
  // there to differ; null is a skill nothing can tell about. Folding the
  // second into the first is the early stock claim this fact refuses.
  const values = !answers ? null : answer === undefined ? false : answer;
  return { forked, settings, edited, values };
}

/** One word from three facts. Any of them makes the place theirs — the
 *  badge answers "is this place mine", and all three are ways of saying
 *  yes. The order decides where a click lands when more than one holds. */
function standingOf(scope: Scope, facts: PlaceFacts): PlaceStanding {
  if (facts.forked) return { scope, standing: "customized", why: "forked" };
  if (facts.settings) return { scope, standing: "customized", why: "settings" };
  if (facts.values) return { scope, standing: "customized", why: "values" };
  if (facts.edited) return { scope, standing: "customized", why: "edited" };
  // Every source has to have spoken before a place can be called stock.
  // One silent source is enough to leave the question open: the mark
  // that is missing is indistinguishable from the mark that is false.
  if (
    facts.settings === null ||
    facts.edited === null ||
    facts.forked === null ||
    facts.values === null
  )
    return { scope, standing: "unknown", why: null };
  return { scope, standing: "stock", why: null };
}

/** How each place stands, in the order the scopes were given. */
export function placeStandings(
  source: PlacesSource,
  kind: ItemKind,
  name: string,
  scopes: Scope[],
): PlaceStanding[] {
  return scopes.map((scope) =>
    standingOf(scope, placeFacts(source, kind, name, scope)),
  );
}

/** One row of the Customize page's index: a package this place holds
 *  something for, every fact that makes it so, and what its overlay sets. */
export interface CustomizedHere {
  kind: ItemKind;
  name: string;
  edited: boolean;
  forked: boolean;
  /** Some package setting of this skill is not the package default here. */
  values: boolean;
  customization: ItemCustomization;
}

/** Every package customized at one place, by the rule the Library's mark
 *  reads. Candidates come from wherever each fact is recorded (the
 *  manifest's overlay and forks tables, and this place's update rows),
 *  and each is put to {@link placeStandings}, so this list and the mark
 *  on a Library row cannot answer differently about the same package. */
export function customizedHere(
  source: PlacesSource,
  scope: Scope,
): CustomizedHere[] {
  const manifest = source.manifests[scopeKey(scope)] ?? null;
  const candidates = new Map<string, [ItemKind, string]>();
  const add = (kind: ItemKind, name: string) =>
    candidates.set(`${kind}:${name}`, [kind, name]);
  for (const item of customizedItems(manifest)) add(item.kind, item.name);
  for (const [kind, byName] of Object.entries(manifest?.forks ?? {}))
    for (const name of Object.keys(byName ?? {})) add(kind as ItemKind, name);
  for (const row of source.rows.values())
    if (sameScope(row.scope, scope) && (row.blockedByLocalEdit || row.forked))
      add(row.kind, row.name);
  for (const [skill, differs] of source.values.get(scopeKey(scope)) ?? [])
    if (differs) add("skill", skill);
  const out: CustomizedHere[] = [];
  for (const [kind, name] of candidates.values()) {
    const facts = placeFacts(source, kind, name, scope);
    if (standingOf(scope, facts).standing !== "customized") continue;
    out.push({
      kind,
      name,
      edited: facts.edited === true,
      forked: facts.forked === true,
      values: facts.values === true,
      customization: itemCustomization(manifest, kind, name),
    });
  }
  return out.sort(
    (a, b) => a.kind.localeCompare(b.kind) || a.name.localeCompare(b.name),
  );
}
