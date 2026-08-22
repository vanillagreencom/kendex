import { commands, type Scope } from "@/bindings";
import { type Draft, emptyDraft, toDraft } from "@/lib/editor-draft";
import { sameScope, scopeKey } from "@/lib/scope";
import { useEditorStore } from "./editor";
import { dropHeld } from "./editor-held";
import { manifestFold, unreadFold } from "./editor-order";
import { named } from "./editor-scopes";

// Every manifest read takes a ticket. Three readers overlap — one place
// at a time, every place at once, and the re-read a save ends with — and
// without tickets the pass that happens to land last wins, reverting a
// place someone just read or just saved.
let reads = 0;
/** Take the next read's ticket. The whole-manifest pass draws from the
 *  same counter as the one-place read below, or the two orderings would
 *  each be right about themselves and wrong about each other. */
export const nextRead = (): number => {
  reads += 1;
  return reads;
};
export const fold = manifestFold();
export const foldUnread = unreadFold();

// Which read the editor on screen is waiting for. Only a read that can
// answer for it takes one: the manifest pass and the re-read a save ends
// with draw no editor, and counting them here would leave the surface
// spinning on a read that was never going to fill it.
let screenReads = 0;

/** Read one place's manifest — the open one, or the one named. */
export const loadManifest = async (
  target?: Scope,
  opts?: { discardEdits?: boolean },
): Promise<void> => {
  const state = () => useEditorStore.getState();
  const scope = target ?? state().scope;
  // Typing that arrives while this read is on its way is newer than the
  // bytes it reads, so it is never replaced. Every reader that must not
  // take still feeds the marks from what it read, and leaves whatever
  // outdated mark the place carries standing — so a save of the older
  // copy is still refused rather than quietly winning.
  //
  // A discard rules on the typing that was there when it was given, which
  // is why it clears `dirty` below rather than being asserted here:
  // keystrokes that land after the instruction are newer than it, and
  // taking them too would destroy work nobody ruled on.
  const takes = () => !state().dirty;
  // An instruction to throw typing away outranks parking, and it lands
  // before anything is awaited: a move made while this read is in flight
  // parks nothing, so the discarded edits cannot come back with it.
  if (opts?.discardEdits === true)
    useEditorStore.setState((current) => ({
      held: dropHeld(current.held, scope),
      ...(sameScope(current.scope, scope) ? { dirty: false } : {}),
    }));
  const token = nextRead();
  // A read answers for the editor only when it reads the place the editor
  // is pointed at; one for somewhere else — the re-read a save ends with —
  // feeds the marks and nothing more, and must not leave the surface
  // waiting on itself.
  // -1 can never equal a claim, which counts up from 1: a read for
  // somewhere else is self-evidently not the one the screen waits on,
  // without resting on where its callers happen to be.
  const drawing = sameScope(state().scope, scope);
  if (drawing) screenReads += 1;
  const claim = drawing ? screenReads : -1;
  // This read speaks for the editor on screen only while it is the newest
  // that could, and the editor still points at the place it read.
  const onScreen = () =>
    claim === screenReads && sameScope(state().scope, scope);
  if (onScreen()) useEditorStore.setState({ loading: true });
  // Started together and settled apart. They answer different questions —
  // what this place declares, and what the form may offer — and joining
  // their failures makes one speak for the other: an inventory that could
  // not be fetched would say the manifest was not read, and the marks for
  // a place kendex just read fine would be masked on its account.
  // Called through this rather than directly: `allSettled` takes promises,
  // so a call that throws where it stands would throw past it, and the
  // whole read would end with nothing said — the silent failure this store
  // exists to avoid.
  const attempt = <T>(call: () => Promise<T>) => Promise.resolve().then(call);
  const [read_manifest, read_inventory] = await Promise.allSettled([
    attempt(() => commands.getManifest(scope)),
    attempt(() => commands.editorInventory(scope)),
  ]);
  const inventory: Awaited<ReturnType<typeof commands.editorInventory>> =
    read_inventory.status === "fulfilled"
      ? read_inventory.value
      : { status: "error", error: String(read_inventory.reason) };
  let manifest: Awaited<ReturnType<typeof commands.getManifest>>;
  if (read_manifest.status === "fulfilled") {
    manifest = read_manifest.value;
  } else {
    const thrown = read_manifest.reason;
    // A transport failure rejects rather than answering, and a read that
    // ends with nothing said is the silent failure this store exists to
    // avoid — the editor says it could not open rather than sitting empty.
    if (onScreen())
      useEditorStore.setState({
        loading: false,
        error: String(thrown),
        ...(takes() ? { draft: null, base: null, dirty: false } : {}),
      });
    // However it went for the screen, this place's manifest was not read:
    // whatever is still in `saved` for it answers for an earlier moment.
    useEditorStore.setState((current) => ({
      unreadPlaces: foldUnread(
        current.unreadPlaces,
        [[scopeKey(scope), `${named(scope)}: ${String(thrown)}`]],
        token,
      ),
    }));
    return;
  }
  if (onScreen()) useEditorStore.setState({ loading: false });
  if (manifest.status === "error") {
    if (onScreen())
      useEditorStore.setState({
        error: manifest.error,
        ...(takes() ? { draft: null, base: null, dirty: false } : {}),
      });
    useEditorStore.setState((current) => ({
      unreadPlaces: foldUnread(
        current.unreadPlaces,
        [[scopeKey(scope), `${named(scope)}: ${manifest.error}`]],
        token,
      ),
    }));
    return;
  }
  // With no manifest here yet the editor still opens, on an empty one:
  // asking someone to press "create" before they can type is a step that
  // decides nothing. Saving is what writes the file.
  const draft = manifest.data.manifest
    ? toDraft(manifest.data.manifest)
    : emptyDraft();
  const read: [string, Draft][] = [[scopeKey(scope), draft]];
  // A read that no longer speaks for the screen, and one that arrived to
  // find typing it must not take, both still know their own place's
  // manifest — so both keep feeding the marks and draw nothing.
  if (!onScreen() || !takes()) {
    useEditorStore.setState((current) => ({
      saved: fold(current.saved, read, token),
      // Except the inventory, which is not the person's to keep: the draft
      // may be theirs, but the choices the form offers — what this place
      // declares, what its catalogs carry — belong to the place. Held with
      // the draft, a form for one project offers another project's skills
      // and hides its own, which saves the wrong thing rather than
      // refusing it.
      unreadPlaces: foldUnread(
        current.unreadPlaces,
        [[scopeKey(scope), null]],
        token,
      ),
      // A typed draft comes back to its own place; the choices beside it
      // do not follow. When this place's inventory would not read, the one
      // still in hand belongs to wherever the editor was last — so the
      // form offers nothing and says why, rather than offering another
      // project's skills to a save about this one.
      ...(onScreen()
        ? inventory.status === "ok"
          ? { inventory: inventory.data }
          : { inventory: null, error: inventory.error }
        : {}),
    }));
    return;
  }
  useEditorStore.setState((current) => ({
    draft,
    // The base belongs to this draft: they are read together and the
    // save sends them together, or a write could carry one file's
    // contents under another file's name.
    base: manifest.data.base,
    // Null rather than whatever was there: the one still in hand belongs
    // to the place last read, and after a move that is a different place.
    // Keeping it offers this place's form another place's skills and hooks
    // and hides its own, so a save here writes choices made about
    // somewhere else. Nothing to offer is the honest state, and the error
    // below says why.
    inventory: inventory.status === "ok" ? inventory.data : null,
    saved: fold(current.saved, read, token),
    unreadPlaces: foldUnread(
      current.unreadPlaces,
      [[scopeKey(scope), null]],
      token,
    ),
    dirty: false,
    // What is in hand is this read's, so whatever rewrote the file before
    // it is no longer under it.
    outdated: current.outdated === scopeKey(scope) ? null : current.outdated,
    error: inventory.status === "ok" ? null : inventory.error,
  }));
};
