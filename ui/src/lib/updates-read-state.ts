import type { ItemKind, Scope, UpdateRow } from "@/bindings";
import {
  NO_UPDATE_STANDING_NOTE,
  UPDATE_NEEDS_CHECK_HERE,
  UPDATES_CHECKING,
} from "@/lib/copy-updates";
import type { ReadState } from "@/lib/read-state";
import { sameScope } from "@/lib/scope";
import { updateWithheld } from "@/lib/update-groups";

/** How the last read of the standing went, and whether one that will
 *  replace it is on its way — an explicit check, or an ordinary reload
 *  from a mount or a return to the window. Every predicate here that ranks
 *  the rows reads this shape; [`workOut`] declares its own, because what it
 *  asks about is the page-wide write hold rather than the read. */
interface PageState {
  read: ReadState;
  checking: boolean;
  reading: boolean;
}

/** Whether the rows on screen are not to be acted on, page-wide: the first
 *  read has not answered, the last one failed, or one that will replace
 *  every row is on its way. A landed read is not enough on its own — a
 *  mount or a return to the window starts a reload over rows that landed
 *  perfectly well, and the answer it brings back is what the captured
 *  values would be committed against. A settling follow flip is not here:
 *  it replaces every row too, but which rows it leaves unconfirmed is its
 *  own scope's, so ask `rowUnsettled` about a given row. The page-wide
 *  hold a flip's write takes is the store's `busy`, which this predicate
 *  does not read — [`workOut`] below is the one that does. */
const unsettled = (state: PageState): boolean =>
  state.read.status !== "landed" || state.checking || state.reading;

/** Whether work the writes exclude is already out: a check building its
 *  report, or a write about to commit under it. One write at a time is what
 *  lets the store's `busy` be a flag rather than a count of who is in. */
export const workOut = (state: { busy: boolean; checking: boolean }): boolean =>
  state.busy || state.checking;

/** Whether a Follow source flip is settling in this row's own place. The
 *  apply behind it moves what is installed in that scope and nowhere else,
 *  so those are the rows it leaves unconfirmed while it runs. Barring a
 *  second write is not this predicate's job — the page-wide write hold
 *  refuses one before any row is asked about — but which rows a settling
 *  flip holds on screen is still scoped, and that is what its readers ask
 *  it for: `grep -rn rowUnsettled ui/src` is the list of them.
 *
 *  Scoped and not page-wide, because the page's Update carries no argument
 *  read off the row: a read in flight cannot stale it, and a flip in the
 *  same place is what still speaks against it. */
const settlingIn = (
  state: { pendingFollows: { scope: Scope }[] },
  row: { scope: Scope },
): boolean =>
  state.pendingFollows.some((one) => sameScope(one.scope, row.scope));

/** Whether one row's facts are not to be acted on: everything `unsettled`
 *  answers for the page, and a follow switch still settling in that row's
 *  scope. For the surface whose actions capture values off the row — the
 *  Updates table sends `row.latest.commit` — so rows about to be replaced
 *  are rows whose values must not be committed. */
export const rowUnsettled = (
  state: PageState & { pendingFollows: { scope: Scope }[] },
  row: { scope: Scope },
): boolean => unsettled(state) || settlingIn(state, row);

/** The package and place the page names. */
type Place = { kind: ItemKind; name: string; scope: Scope };

/** This package's row in the place the page names, or undefined where the
 *  update read never covered it. One lookup behind both what that read says
 *  about the package and whether it speaks for the place at all. */
const rowFor = (
  state: { rows: UpdateRow[] },
  place: Place | null,
): UpdateRow | undefined =>
  state.rows.find(
    (one) =>
      place != null &&
      one.kind === place.kind &&
      one.name === place.name &&
      sameScope(one.scope, place.scope),
  );

/** Whether a landed read left a row for this place. Private because it is not
 *  a second answer for a caller to weigh: [`updatesReadNote`] is where it
 *  decides anything. */
const covers = (
  state: PageState & { rows: UpdateRow[] },
  place: Place | null,
): boolean =>
  state.read.status === "landed" && rowFor(state, place) !== undefined;

/** Why the update read withholds an Update for the place the package page
 *  names, as a fact about the package — or null where it has no such fact.
 *
 *  The kind's refusal outranks everything here, the way [`updateWithheld`]
 *  ranks it for the Updates table: core derives it from the kind alone, so it
 *  is why this place can never be updated one package at a time, where every
 *  other reason is why not right now. Told to check again instead, a person
 *  offline would retry something no successful check can win.
 *
 *  A read that has not landed says nothing here. A first read still on its
 *  way has not spoken for this place, and one that failed left the rows here
 *  last-known — neither is a fact about the package, and what the read itself
 *  is doing is [`updatesReadNote`]'s to say. A read merely running does not
 *  withhold a row that exists: the row is the last answer and still the truth
 *  about it.
 *
 *  Only a settled read may say the check never covered this place, which is
 *  [`unsettled`] and not the read status alone: a landed read with a focus
 *  reload or a Check in flight is a read about to speak, and calling its
 *  silence a fact is the blur `read-state.ts` forbids. */
export const packageUpdateNote = (
  state: PageState & { rows: UpdateRow[] },
  place: Place | null,
): string | null => {
  const row = rowFor(state, place);
  if (row?.noPerPackageUpdate != null) return row.noPerPackageUpdate;
  if (state.read.status !== "landed") return null;
  if (row) return updateWithheld(row);
  return unsettled(state) ? null : NO_UPDATE_STANDING_NOTE;
};

/** How the update read itself is standing, when that is all there is to say
 *  about this place.
 *
 *  Kept apart from [`packageUpdateNote`] because it answers a different
 *  question: this is the standing behind every package on the machine, not a
 *  fact about the one on screen. `versions.ts` [`updateOffer`] ranks it last
 *  for that reason — a check that has not finished must not stand in for a
 *  read of this package that actually failed.
 *
 *  Silent where a landed read already left a row here. A check merely running
 *  does not withhold a row that exists: the row is the last answer and still
 *  the truth about it, and the page keeps its version-changing controls on
 *  screen through a check, disabled by `use-package-data.ts`
 *  [`useVersionsBusy`]. A read that has not landed is the other case — its
 *  rows here are last-known and nothing has confirmed them — so this speaks
 *  for the place instead. */
export const updatesReadNote = (
  state: PageState & { rows: UpdateRow[] },
  place: Place | null,
): string | null => {
  if (covers(state, place)) return null;
  if (state.read.status === "pending") return UPDATES_CHECKING;
  if (state.read.status === "failed") return UPDATE_NEEDS_CHECK_HERE;
  return unsettled(state) ? UPDATES_CHECKING : null;
};

/** Every installed package that requires the one this place names, when
 *  that is why it is here — the fact behind `derived`, so the page says who
 *  brought it rather than that something did. Empty while no row speaks for
 *  the place: a package nothing requires, a bundle member, and a read that
 *  has not answered yet all read the same, and the header simply says
 *  nothing rather than guessing at a parent.
 *
 *  The row's own array is handed back, and the no-row answer is one shared
 *  empty array rather than a fresh one: this is read through a store
 *  selector, and a new reference on every call is a render loop. */
const NO_PARENTS: string[] = [];

export const packageRequiredBy = (
  state: { rows: UpdateRow[] },
  place: { kind: ItemKind; name: string; scope: Scope } | null,
): string[] =>
  state.rows.find(
    (one) =>
      place != null &&
      one.kind === place.kind &&
      one.name === place.name &&
      sameScope(one.scope, place.scope),
  )?.requiredBy ?? NO_PARENTS;
