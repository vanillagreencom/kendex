import {
  commands,
  type EditorInventory,
  type Scope,
  type ScopeSettings,
  type SettingsEdit,
} from "@/bindings";
import { type Draft, emptyDraft, toDraft } from "@/lib/editor-draft";
import { scopeKey } from "@/lib/scope";

// The editor's scope-keyed caches: what is read per place, how it is
// written, and how the open place's answer is found. Split out from the
// store so there is one module to look at when asking whether a value can
// belong to the wrong place: the store only calls these.

/** The inventory of the place the editor is open at, and no other. A
 *  lookup rather than a field, so the answer is either this place's or
 *  absent — there is no third state where another place's read is still
 *  on screen. */
export const openInventory = (state: {
  scope: Scope;
  inventories: Record<string, EditorInventory>;
}): EditorInventory | null => state.inventories[scopeKey(state.scope)] ?? null;

/** What one scope's read produced, written into that scope's key — or its
 *  absence, when the read produced nothing.
 *
 *  Every scope-keyed cache is written through here and nowhere else. A
 *  cache that is only written on success keeps its last good answer for a
 *  place that has stopped reading, and the place then goes on being marked
 *  from a manifest nobody can see any more. Passing the failure through as
 *  `null` is what makes an unread place unread rather than stale, and
 *  having one writer is what stops the next cache from needing its own
 *  invalidation point. */
const recorded = <T>(
  cache: Record<string, T>,
  scope: Scope,
  value: T | null,
): Record<string, T> => {
  const next = { ...cache };
  if (value === null) delete next[scopeKey(scope)];
  else next[scopeKey(scope)] = value;
  return next;
};

/** The three reads the editor opens one place on, made together so the
 *  page describes one moment rather than three. */
export const readPlace = (scope: Scope) =>
  Promise.all([
    commands.getManifest(scope),
    commands.editorInventory(scope),
    commands.getScopeSettings(scope),
  ]);

/** The manifest a read hands the editor, or null where it could not be
 *  read at all. With no manifest file here yet the editor still opens, on
 *  an empty one: asking someone to press "create" before they can type is
 *  a step that decides nothing. Saving is what writes the file. */
export const readDraft = (
  manifest: Awaited<ReturnType<typeof commands.getManifest>>,
): Draft | null =>
  manifest.status !== "ok"
    ? null
    : manifest.data.manifest
      ? toDraft(manifest.data.manifest)
      : emptyDraft();

/** The first of a read's other halves that failed, said out loud: a
 *  settings section that is simply missing looks like a skill that ships
 *  none. */
export const readError = (
  inventory: Awaited<ReturnType<typeof commands.editorInventory>>,
  settings: Awaited<ReturnType<typeof commands.getScopeSettings>>,
): string | null => {
  if (inventory.status === "error") return inventory.error;
  if (settings.status === "error") return settings.error;
  return null;
};

/** Each named scope's saved manifest, keyed by scope. A read that fails is
 *  left out rather than recorded as an empty manifest: a place nobody could
 *  read is not a place holding nothing, and the marks tell them apart. */
const manifestsOf = async (scopes: Scope[]): Promise<Record<string, Draft>> => {
  const loaded = await Promise.all(
    scopes.map((scope) => commands.getManifest(scope)),
  );
  const saved: Record<string, Draft> = {};
  for (const [index, response] of loaded.entries()) {
    if (response.status !== "ok") continue;
    saved[scopeKey(scopes[index])] = response.data.manifest
      ? toDraft(response.data.manifest)
      : emptyDraft();
  }
  return saved;
};

/** Each named scope's settings read, keyed by scope. Left out the same way
 *  a manifest is: a place whose read failed is a place nobody can answer
 *  for, and the settings half of a mark tells that from a place holding
 *  nothing. Global answers `applies: false` rather than failing, so it is
 *  recorded like any other. */
const settingsOf = async (
  scopes: Scope[],
): Promise<Record<string, ScopeSettings>> => {
  const loaded = await Promise.all(
    scopes.map((scope) => commands.getScopeSettings(scope)),
  );
  const read: Record<string, ScopeSettings> = {};
  for (const [index, response] of loaded.entries())
    if (response.status === "ok") read[scopeKey(scopes[index])] = response.data;
  return read;
};

/** Both halves of every named place, read together. The marks answer from
 *  the two records at once, so a pass that filled one and not the other
 *  would leave every place it touched unknown. */
export const placesOf = (scopes: Scope[]) =>
  Promise.all([manifestsOf(scopes), settingsOf(scopes)]);

/** What every fresh read of a place resets on the page, whichever way the
 *  read went: no drafts in hand, nothing unsaved, no refusal standing. */
export const opening = {
  settingsEdits: [] as SettingsEdit[],
  dirty: false,
  manifestDirty: false,
  stale: false,
};

/** The scope-keyed caches the marks are drawn from. */
interface PlaceCaches {
  saved: Record<string, Draft>;
  inventories: Record<string, EditorInventory>;
  savedSettings: Record<string, ScopeSettings>;
}

/** What one place's read records: each half under that place's key, and
 *  gone where that half could not be read. Presence is what says a read
 *  landed, and a mark off a kept entry answers out of a file nobody can
 *  see any more. Written as one object, so a place's three halves are
 *  never left from different reads. */
export const recordedRead =
  (
    scope: Scope,
    [manifest, inventory, settings]: Awaited<ReturnType<typeof readPlace>>,
  ) =>
  (held: PlaceCaches): PlaceCaches => ({
    saved: recorded(held.saved, scope, readDraft(manifest)),
    inventories: recorded(
      held.inventories,
      scope,
      inventory.status === "ok" ? inventory.data : null,
    ),
    savedSettings: recorded(
      held.savedSettings,
      scope,
      settings.status === "ok" ? settings.data : null,
    ),
  });

/** One read over several places, folded into what is held. Merged per
 *  place rather than replacing the record, so a read of some places
 *  leaves the rest as they were. */
export const mergedPlaces =
  (
    scopes: Scope[],
    [manifests, settings]: Awaited<ReturnType<typeof placesOf>>,
  ) =>
  (held: Pick<PlaceCaches, "saved" | "savedSettings">) => ({
    saved: scopes.reduce(
      (out, scope) => recorded(out, scope, manifests[scopeKey(scope)] ?? null),
      held.saved,
    ),
    savedSettings: scopes.reduce(
      (out, scope) => recorded(out, scope, settings[scopeKey(scope)] ?? null),
      held.savedSettings,
    ),
  });
