import type { Scope } from "@/bindings";
import { commands } from "@/bindings";
import { sameScope } from "@/lib/scope";
import { useEditorStore } from "./editor";

/** Tell the editor that something outside it rewrote a place's kendex.toml.
 *
 *  Nearly every mutation does: forking, discarding edits, moving a hold,
 *  adopting, toggling, subscribing, installing, settling a finding. The
 *  editor holds a whole manifest read at some earlier moment, and a save
 *  writes that whole copy back — so without this, the next save silently
 *  undoes whatever was just recorded, and the marks drawn from `saved` stay
 *  stale until a refocus.
 *
 *  Refusing comes first and re-reading second, so no caller can order this
 *  wrong. The place is marked outdated before anything is awaited, which is
 *  what refuses a save; the re-read below takes the mark off again, and only
 *  when it lands on the same untouched draft it started from. A copy in hand
 *  with typing in it is never replaced — that would choose losing the typing
 *  over losing the record, and the mark makes the save say so instead. */
export async function manifestRewritten(scope: Scope): Promise<void> {
  const editor = useEditorStore.getState();
  if (sameScope(editor.scope, scope)) editor.outdate(scope);
  await editor.loadAll();
  const after = useEditorStore.getState();
  // Typing parked at some other place is deliberately not marked here: it
  // travels with the base it was read against, so the write refuses it on
  // the file's own evidence when its place is opened again.
  if (!sameScope(after.scope, scope)) return;
  // Typing that arrived while the manifests were being read is newer than
  // the file this is about, so it is kept — and now the mark is measured
  // rather than assumed. Most of these actions rewrite installed files and
  // the lock and never touch kendex.toml: an ordinary update is one. A file
  // that is still the one the draft came from has nothing under it, and
  // refusing that save would teach people to reload away their own typing.
  if (after.dirty) {
    // A read that never arrives cannot say the file is still the one the
    // draft came from, so it does not get to take the mark off. The
    // transport can drop this call the same as any other, and a caller
    // that fired this and walked away would otherwise get an unhandled
    // rejection and the reader nothing at all.
    const read = await commands
      .getManifest(scope)
      .catch((thrown: unknown) => String(thrown));
    const moved =
      typeof read === "string" ||
      read.status !== "ok" ||
      read.data.base !== after.base;
    if (moved) after.outdate(scope);
    else after.current(scope);
    // A read that failed leaves this place unread like any other: what is
    // still in hand for it answers for an earlier moment, and the note
    // says so and offers the retry.
    if (typeof read === "string") after.unread(scope, read);
    return;
  }
  // Marked again before the re-read, since the editor may have moved here
  // while the manifests were being read: typing that lands during this one
  // finds the save already refused, and the read declines to replace it.
  after.outdate(scope);
  await after.load(scope);
}
