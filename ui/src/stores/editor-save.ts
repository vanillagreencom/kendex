import type { Scope } from "@/bindings";
import { commands } from "@/bindings";
import {
  OUTDATED_DRAFT_BODY,
  OUTDATED_DRAFT_TITLE,
  RELOAD_SETTINGS_LABEL,
} from "@/lib/copy-forks";
import { sameScope, scopeKey } from "@/lib/scope";
import { useAuditStore } from "./audit";
import { useEditorStore } from "./editor";
import { settleHeld } from "./editor-held";
import { named } from "./editor-scopes";
import { useProblemsStore } from "./problems";
import { useScanStore } from "./scan";

type Load = (scope?: Scope, opts?: { discardEdits?: boolean }) => Promise<void>;

/** The refusal, for a place that is no longer the one on screen. */
const outdatedElsewhere = (scope: Scope) =>
  `${named(scope)}: ${OUTDATED_DRAFT_BODY}`;

// Which save the screen's saving state belongs to. Two can be in flight —
// nothing stops a second press once the first is away — and everything
// after the await is about the place that was written, not whichever place
// is open when the response lands.
let writes = 0;

/** Write the copy in hand to the place it was read from, then re-read that
 *  place. Refuses when what is in hand predates a rewrite of that same
 *  file: putting it back would undo the record that rewrite made.
 *
 *  Twice over, and deliberately. The mark below is what the app knows: it
 *  is set the moment something else writes, so a save inside that window
 *  never reaches the disk and the reason is on screen without a round
 *  trip. The base sent with the write is what the *file* knows, and it
 *  needs nobody to have noticed anything — a writer that never tells the
 *  editor it wrote still cannot be overwritten. */
const refuseOnScreen = (scope: Scope, load: Load) =>
  useProblemsStore.getState().showError({
    title: OUTDATED_DRAFT_TITLE,
    message: OUTDATED_DRAFT_BODY,
    actions: [
      {
        label: RELOAD_SETTINGS_LABEL,
        // Reloading is the deliberate act of taking the newer file over
        // what is on screen; every other read here leaves typing alone.
        onClick: () => void load(scope, { discardEdits: true }),
      },
    ],
  });

export const saveManifest = async (): Promise<void> => {
  // Scope, draft and base are one value: read apart, a place switch between
  // the reads sends one place's manifest to another place's file, or writes
  // it against the base of a file it never came from.
  const { scope, draft, base, outdated, load } = useEditorStore.getState();
  if (!draft) return;
  // What is in hand was read before this place's manifest was rewritten,
  // so writing it would put the older file back over what was recorded —
  // a fork's own entry lives nowhere else. Refusing loudly beats choosing
  // silently between losing that and losing what was typed.
  if (outdated === scopeKey(scope)) {
    refuseOnScreen(scope, load);
    return;
  }
  writes += 1;
  const token = writes;
  const mine = () => token === writes;
  const onScreen = () =>
    mine() && sameScope(useEditorStore.getState().scope, scope);
  useEditorStore.setState({ saving: true });
  let response: Awaited<ReturnType<typeof commands.updateManifest>>;
  try {
    response = await commands.updateManifest(scope, draft, base);
  } catch (thrown) {
    if (mine())
      useEditorStore.setState({
        saving: false,
        error: `${named(scope)}: ${thrown}`,
      });
    return;
  }
  if (mine()) useEditorStore.setState({ saving: false });
  // A newer save owns what the screen says about saving.
  if (!mine()) return;
  if (response.status === "error") {
    // The write refused because the file is not the one this copy came
    // from. Nothing marked the place — that is the point of asking the
    // file — so the same refusal the mark would have raised is raised
    // here, with the same way out.
    if (response.error.kind === "stale") {
      if (onScreen()) refuseOnScreen(scope, load);
      else useEditorStore.setState({ error: outdatedElsewhere(scope) });
      // The place is marked too, so the Save bar's next press is refused
      // without another round trip.
      useEditorStore.getState().outdate(scope);
      return;
    }
    // The note is about the place that was written, which may not be the
    // one on screen any more — so it names that place rather than letting
    // the reader assume the one in front of them.
    const message = response.error.message;
    useEditorStore.setState({
      error: onScreen() ? message : `${named(scope)}: ${message}`,
    });
    return;
  }
  if (onScreen()) useEditorStore.setState({ error: null });
  const written = response.data.base;
  // The write puts down things nobody typed: the default source and
  // harnesses a first manifest is seeded with, and a name derived for a
  // custom hook that arrived without one. So the file that landed is not
  // the copy that was sent, and no copy in hand may claim it.
  const wroteMore = response.data.wroteMore;
  // The write landed on one place's file, so it settles that place's copy
  // wherever that copy is. A move made while the write was away parks it,
  // and a parked copy left carrying the base from before its own write has
  // its next save refused — the person told to reload over typing that is
  // already on disk.
  useEditorStore.setState((current) => ({
    held: settleHeld(current.held, scope, written, draft, wroteMore),
  }));
  // What is on screen is what the file now holds, so it is no longer
  // unsaved — the Save bar comes down and the place chips come live. Only
  // for the copy that was written: typing that arrived while the write was
  // away is a newer draft, and it stays unsaved until its own save. `edit`
  // builds a new draft rather than mutating, so identity is that test, and
  // the re-read below leaves a newer draft alone for the same reason.
  if (onScreen()) {
    // Whether the copy that went is still the one in hand: only then is
    // there nothing unsaved left here.
    const wrote = useEditorStore.getState().draft === draft;
    if (written === null || wroteMore) {
      // Nothing in hand is this file. Either it could not be read back to
      // say what it is — and reading it here to find out is the one thing
      // this must never do, since that pairs a base with content nobody
      // read with it — or it holds something the write put there, which no
      // copy that went carries and no edit made from one does either.
      //
      // So the place is refused, and the re-read below is what takes the
      // refusal off: it lands on the file and settles a copy nobody has
      // typed over. Typing that arrives before it does keeps the refusal,
      // which is the answer — that copy would write what the file gained
      // back out of existence, and every check it passes would say it was
      // fine.
      useEditorStore.getState().outdate(scope);
    } else {
      // The base describes the file, and the file is what was just
      // written — so it moves whether or not the copy on screen is still
      // the one that went. Typing that arrived mid-write descends from
      // this write like any other edit does, and leaving the old base
      // behind would have its save refused for a change it made itself.
      useEditorStore.setState({ base: written });
    }
    // Either way the write landed, so what is on screen is saved — while
    // nothing was typed over it.
    if (wrote) useEditorStore.setState({ dirty: false });
  } else if (written === null) {
    // The same fact off screen: the file was written and could not be read
    // back, so the place is marked and whatever is parked there asks for a
    // reload when it is opened rather than writing blind.
    useEditorStore.getState().outdate(scope);
  }
  // Re-read the place that was written, never whichever is open now, or
  // its saved manifest keeps the pre-save content and its mark with it.
  await load(scope);
  await useAuditStore.getState().refresh();
  await useScanStore.getState().refresh();
};
