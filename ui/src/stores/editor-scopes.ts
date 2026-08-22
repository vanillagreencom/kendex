import { commands, type Scope } from "@/bindings";
import { type Draft, emptyDraft, toDraft } from "@/lib/editor-draft";
import { scopeName, scopePath } from "@/lib/labels";
import { scopeKey } from "@/lib/scope";
import { useSettingsStore } from "./settings";

/** What a place is called in a message about it: the full path, so two
 *  projects sharing a folder name are never confused for each other. */
export const named = (scope: Scope): string =>
  scopePath(scope) ?? scopeName(scope);

/** Every place a mark can be drawn for: the user's own, and each project
 *  the settings know about. Startup reads run side by side, so the project
 *  list may still be on its way — without waiting for it this would mark
 *  only the global scope. */
async function everyScope(): Promise<Scope[]> {
  const settings = useSettingsStore.getState();
  if (!settings.settings) await settings.load();
  // A read that could not open the file resolves like any other — it says
  // so its own way — and leaves nothing here to list. Carrying on would
  // answer for the user's own place and call that every place: the pass
  // would report success, and every project's packages would read as
  // untouched with nobody having looked at them.
  if (!useSettingsStore.getState().settings)
    throw new Error("your projects could not be read");
  return scopesNow();
}

/** Every place there is right now, read without awaiting anything.
 *
 *  A pass takes its list of places when it starts and answers with it much
 *  later. Asked again at the moment its answer is written, this says which
 *  of those places are still places — so a project unregistered in between
 *  cannot be put back by a read that was already on its way. */
export function scopesNow(): Scope[] {
  const projects = useSettingsStore.getState().settings?.projects ?? [];
  return [
    { scope: "global" },
    ...projects.map((root) => ({ scope: "project" as const, root })),
  ];
}

/** Read each place's manifest: the ones that answered, keyed by scope, and
 *  the reason each of the rest did not. A place that would not read is
 *  named rather than only implied — the marks alone cannot say why. */
export async function readManifests(): Promise<{
  read: [string, Draft][];
  /** Each place whose read failed, with what it said. The last manifest
   *  that loaded for them is kept, so without this the join cannot tell a
   *  manifest it just read from one it read some time ago and could not
   *  re-check — and the reason travels with the place rather than beside
   *  it, so a place that reads again takes its reason with it. */
  unread: [string, string][];
}> {
  const scopes = await everyScope();
  // Each read answers for its own place. Left to reject, one bad manifest
  // takes the whole batch down and every readable place with it — the
  // opposite of the per-place result this returns.
  const loaded = await Promise.all(
    scopes.map((scope) =>
      commands.getManifest(scope).catch((thrown: unknown) => ({
        status: "error" as const,
        error: String(thrown),
      })),
    ),
  );
  const read: [string, Draft][] = [];
  const unread: [string, string][] = [];
  for (const [index, response] of loaded.entries()) {
    if (response.status !== "ok") {
      unread.push([
        scopeKey(scopes[index]),
        `${named(scopes[index])}: ${response.error}`,
      ]);
      continue;
    }
    read.push([
      scopeKey(scopes[index]),
      response.data.manifest ? toDraft(response.data.manifest) : emptyDraft(),
    ]);
  }
  return { read, unread };
}
