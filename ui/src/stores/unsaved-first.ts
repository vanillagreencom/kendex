import type { Scope } from "@/bindings";
import {
  UNSAVED_FIRST_BODY,
  UNSAVED_FIRST_TITLE,
  unsavedFirstSteps,
} from "@/lib/copy-forks";
import { scopeName } from "@/lib/labels";
import { sameScope, scopeKey } from "@/lib/scope";
import { useEditorStore } from "./editor";
import { useProblemsStore } from "./problems";

/** Whether unsaved customization for a place refuses a write to it, saying
 *  so if it does.
 *
 *  Every mutation that rewrites a place's kendex.toml asks this before it
 *  starts. The editor holds a whole copy of that file and a save writes the
 *  whole copy back, so a write that lands underneath one makes the copy
 *  unsavable — and the only way on from there discards what was typed.
 *
 *  The typing may be on screen or parked behind another place: moving
 *  between places keeps typing rather than dropping it, and a move is not a
 *  ruling on it. Reaching only the copy on screen would let where someone
 *  happens to be standing decide whether the write is refused, which is not
 *  a choice anyone made. Anything parked is unsaved by construction.
 *
 *  This lives in one place because the list of writers is not fixed: a new
 *  one that forgot to ask would be a control that stays live while the file
 *  moves under it, which is exactly the fault this closes. */
export function refusesForUnsaved(scope: Scope): boolean {
  const editor = useEditorStore.getState();
  const parked = editor.held[scopeKey(scope)] !== undefined;
  if (!parked && !(editor.dirty && sameScope(editor.scope, scope)))
    return false;
  useProblemsStore.getState().showError({
    title: UNSAVED_FIRST_TITLE,
    message: UNSAVED_FIRST_BODY,
    // Parked typing is not on screen, so the way back to it is named.
    steps: unsavedFirstSteps(parked ? scopeName(scope) : null),
  });
  return true;
}

/** The same question about several places at once, for one click that
 *  writes them all.
 *
 *  Asked per place inside the loop, the first refusal stops that place and
 *  the loop carries on writing the others — one click leaving the package
 *  changed in two projects and not the third, with nothing said about
 *  which. A package-wide action either goes everywhere or nowhere. */
export function refusesForUnsavedIn(scopes: Scope[]): boolean {
  const editor = useEditorStore.getState();
  const held = scopes.find(
    (scope) => editor.held[scopeKey(scope)] !== undefined,
  );
  const onScreen = scopes.find(
    (scope) => editor.dirty && sameScope(editor.scope, scope),
  );
  const blocking = held ?? onScreen;
  if (!blocking) return false;
  useProblemsStore.getState().showError({
    title: UNSAVED_FIRST_TITLE,
    message: UNSAVED_FIRST_BODY,
    steps: unsavedFirstSteps(held ? scopeName(blocking) : null),
  });
  return true;
}

// Set only while a package-wide action is writing one of its places, and
// read by the funnel that raises the failure — which is called from inside
// the action and so cannot be handed this any other way. One slot rather
// than a stack: these all run under a busy flag that keeps a second
// package-wide action from starting while one is in flight.
let rest: (() => void) | null = null;

/** What a retry raised during a package-wide action should do: the places
 *  that are left, not the one place the message came from. Null when the
 *  failure is a single place's own. */
export function retryTheRest(): (() => void) | null {
  return rest;
}

/** Run one package-wide action over every place it is about, or over none.
 *
 *  Two questions, because they are different questions. The first is asked
 *  before anything is written: a set that already has unsaved typing in it
 *  is not started, so one click cannot leave the package changed in two
 *  projects and not the third. The second is asked again before each place,
 *  because every await in between is a window someone can type in — and
 *  these actions return nothing, so a refusal inside one is invisible from
 *  out here.
 *
 *  A refusal stops the loop rather than skipping past it. The places
 *  already done are done; writing the rest over what someone just typed
 *  would be the same loss one place along. */
export async function inEveryPlace(
  scopes: Scope[],
  act: (scope: Scope) => Promise<boolean>,
): Promise<void> {
  if (refusesForUnsavedIn(scopes)) return;
  for (const [at, scope] of scopes.entries()) {
    if (refusesForUnsaved(scope)) return;
    // What Retry should mean while this place is being written: the rest of
    // the package-wide action, starting here. The place that failed is
    // where the message comes from, but finishing only that place leaves
    // the ones after it undone with nothing left to say so.
    rest = () => void inEveryPlace(scopes.slice(at), act);
    // And stop when the machine would not take it. The action has already
    // said why; going on to the next place would leave the package changed
    // in some of them and not others, under one click that reported a
    // single failure and looked otherwise done.
    let took: boolean;
    try {
      took = await act(scope);
    } finally {
      // However this leaves, including by throwing. Left set, the next
      // failure anywhere in the app — a different package, a single place —
      // would offer a retry that writes the rest of this one.
      rest = null;
    }
    if (!took) return;
  }
}
