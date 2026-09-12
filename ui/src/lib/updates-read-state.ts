import type { ItemKind, ScanResult, Scope, UpdateRow } from "@/bindings";
import {
  NO_UPDATE_STANDING_NOTE,
  UPDATE_NEEDS_CHECK_HERE,
  UPDATES_CHECKING,
} from "@/lib/copy-updates";
import { groupItems, installedCount } from "@/lib/derive";
import type { PackageOf } from "@/lib/package-identity";
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

/** Whether the rows on screen are not to be acted on: the first read has
 *  not answered, the last one failed, or one that will replace every row is
 *  on its way. A landed read is not enough on its own — a mount or a return
 *  to the window starts a reload over rows that landed perfectly well, and
 *  the answer it brings back is what the captured values would be committed
 *  against.
 *
 *  Page-wide, because every read of the standing replaces every row. The
 *  write hold is a separate question and a separate flag: [`workOut`] below
 *  is what reads the store's `busy`, and this never does.
 *
 *  `grep -rn readUnsettled ui/src` is the list of surfaces that ask. */
export const readUnsettled = (state: PageState): boolean =>
  state.read.status !== "landed" || state.checking || state.reading;

/** What an Updates page with nothing to list is actually saying about this
 *  machine. Three answers one judge keeps apart, because two of them are
 *  routinely mistaken for the third:
 *
 *  - `nothing-installed`: the machine scan counts nothing installed, so no
 *    check could speak for anything. Read from that count and never from
 *    the update rows: core's `updates()` walks the planned REMOTE
 *    declarations alone, so a machine holding adopted, local, in-place or
 *    unmanaged content has no update rows at all while the Library's table
 *    and Home's Installed tile count its packages. Deciding it from the
 *    rows would answer that machine "Nothing installed yet" and take away
 *    its check.
 *  - `unchecked`: something is installed, nothing noteworthy is on the
 *    page, and no fetch has ever reached a source. Nothing here has
 *    standing to call anything current.
 *  - `current`: a fetch reached a source and left nothing noteworthy.
 *
 *  Asked only where the page has no list to draw; the rows themselves are
 *  the answer wherever there is one. */
export type EmptyStanding =
  | { kind: "nothing-installed" }
  | { kind: "unchecked" }
  | { kind: "current" };

/** How many packages the machine holds, or null where nothing can say —
 *  the count [`emptyStanding`] may call a machine empty on. Only a
 *  settled, complete, successful scan produces one, because the caller
 *  words a zero as "Nothing installed yet" and takes the check away with
 *  it.
 *
 *  A failed re-read leaves the last result and its generation standing
 *  (`stores/scan.ts`), so a kept zero would report a machine nothing has
 *  looked at since. A landed scan carrying `missingProjects` read part of
 *  the machine, and a project it could not open is where the content may
 *  be. A join answering about another scan cannot group what is on screen,
 *  which is the gate `usePackageIndex` puts on every other counter.
 *
 *  Counted in the package unit through [`installedCount`], so this and the
 *  Library's table can never disagree about what one package is. */
export const scannedInstalled = (
  scan: ScanResult | null,
  /** The scan store's standing error, which outlives the result it failed
   *  to replace. */
  scanError: string | null,
  packageOf: PackageOf | null,
): number | null => {
  if (scan === null || packageOf === null || scanError !== null) return null;
  if (scan.missingProjects.length > 0) return null;
  return installedCount(groupItems(scan.items, packageOf));
};

/** Only a count that says the machine is empty makes it empty. A count
 *  nobody can take yet falls to the `unchecked`/`current` pair, which keeps
 *  the check on screen rather than offering a marketplace to a machine that
 *  may be full. */
export const emptyStanding = (
  /** Packages the machine scan counts, or null where the scan has not
   *  landed or its join has not answered for what is on screen. */
  installed: number | null,
  /** Unix seconds of the last successful fetch, as the overview reports it. */
  lastFetched: number | null,
): EmptyStanding => {
  if (installed === 0) return { kind: "nothing-installed" };
  return lastFetched === null ? { kind: "unchecked" } : { kind: "current" };
};

/** Whether the update rows can be read as last-known facts: a read that
 *  landed, or a failed re-check that kept the rows it had. One rule for
 *  every reader of the per-place facts — the Library, the package header
 *  and the Customize page — so a fork or an edit is never a fact on one
 *  page and unknown on the next. A read still on its way, or a first
 *  read that failed with nothing kept, has nothing to read. */
export const rowsKnown = (state: {
  read: { status: string };
  rows: unknown[];
}): boolean =>
  state.read.status === "landed" ||
  (state.read.status === "failed" && state.rows.length > 0);

/** Whether work the writes exclude is already out: a check building its
 *  report, or a write about to commit under it. One write at a time is what
 *  lets the store's `busy` be a flag rather than a count of who is in. */
export const workOut = (state: { busy: boolean; checking: boolean }): boolean =>
  state.busy || state.checking;

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
 *  [`readUnsettled`] and not the read status alone: a landed read with a focus
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
  return readUnsettled(state) ? null : NO_UPDATE_STANDING_NOTE;
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
  return readUnsettled(state) ? UPDATES_CHECKING : null;
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
 *  selector, and a fresh reference on every call is a render loop. */
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

/** Whether this place's fork carries the person's own edits. A state and
 *  not a decision: the engine keeps those bytes and records them, so
 *  nothing here is withheld and nothing is offered. False while no row
 *  speaks for the place, which reads as the plain fork the header already
 *  shows. */
export const packageForkEdited = (
  state: { rows: UpdateRow[] },
  place: { kind: ItemKind; name: string; scope: Scope } | null,
): boolean =>
  state.rows.some(
    (one) =>
      place != null &&
      one.kind === place.kind &&
      one.name === place.name &&
      sameScope(one.scope, place.scope) &&
      one.forkEdited,
  );
