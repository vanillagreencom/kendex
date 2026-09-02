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

/** Why the package page has no Update for the place it names, or null when
 *  nothing withholds one.
 *
 *  The kind's refusal outranks the read, the way [`updateWithheld`] ranks
 *  it for the Updates table: core derives it from the kind alone, so it is
 *  why this place can never be updated one package at a time, where every
 *  other reason is why not right now. Told to check again instead, a
 *  person offline would retry something no successful check can win.
 *
 *  Then how the read went, which the row cannot say: a first read still on
 *  its way has not spoken for this place, and one that failed left the
 *  rows here last-known. A read merely running does not withhold a row
 *  that exists — the row is the last answer and still the truth about it.
 *
 *  Only a settled read may say the check never covered this place, which
 *  is [`unsettled`] and not the read status alone: a landed read with a
 *  focus reload or a Check in flight is a read about to speak, and calling
 *  its silence a fact is the blur `read-state.ts` forbids. */
export const packageUpdateNote = (
  state: PageState & { rows: UpdateRow[] },
  place: { kind: ItemKind; name: string; scope: Scope } | null,
): string | null => {
  const row = state.rows.find(
    (one) =>
      place != null &&
      one.kind === place.kind &&
      one.name === place.name &&
      sameScope(one.scope, place.scope),
  );
  if (row?.noPerPackageUpdate != null) return row.noPerPackageUpdate;
  if (state.read.status === "pending") return UPDATES_CHECKING;
  if (state.read.status === "failed") return UPDATE_NEEDS_CHECK_HERE;
  if (row) return updateWithheld(row);
  return unsettled(state) ? UPDATES_CHECKING : NO_UPDATE_STANDING_NOTE;
};
