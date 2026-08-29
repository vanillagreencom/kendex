import {
  commands,
  type EditorInventory,
  type Scope,
  type ScopeSettings,
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
export const recorded = <T>(
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

/** Each named scope's saved manifest, keyed by scope. A read that fails is
 *  left out rather than recorded as an empty manifest: a place nobody could
 *  read is not a place holding nothing, and the marks tell them apart. */
export const manifestsOf = async (
  scopes: Scope[],
): Promise<Record<string, Draft>> => {
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
export const settingsOf = async (
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
