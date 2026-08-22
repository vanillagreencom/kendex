import type { UpdateRow } from "@/bindings";
import { packageCount } from "@/lib/update-groups";

// Which rows are worth saying something about, and where. Pure over a list
// the store fetches, so every screen asks the same question the same way.

/** A row worth a line on the page: a newer version, a package gone from
 *  its source, or installs disagreeing on their version — each a standing
 *  fact someone can act on. */
const noteworthy = (row: UpdateRow): boolean =>
  row.updateAvailable || row.removedUpstream || row.mixed;

/** The sidebar badge's number: packages with news someone would want to
 *  hear, counted once however many places they are installed in. Ignored
 *  ones asked not to be counted; held ones still count — a hold is "not
 *  yet", not "never tell me". */
export const visibleUpdateCount = (rows: UpdateRow[]): number =>
  packageCount(visibleUpdates(rows));

/** The Updates page's main list: everything noteworthy that has not been
 *  muted. */
export const visibleUpdates = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => noteworthy(row) && !row.ignored);

/** The collapsed "hidden updates" section: muted packages whose news is
 *  still real — with the way back out. */
export const hiddenUpdates = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => noteworthy(row) && row.ignored);

/** The packages Home asks you to decide about: files edited by hand, with
 *  the keep-as-your-own decision still open. A fork is not one of them —
 *  that decision is already made, and this row's words are about making it.
 *  An edited fork is still held and still has an exit: `check` reports it
 *  and the package page offers the discard. Home is deliberately the
 *  quieter surface here, not a disagreeing one. */
export const awaitingForkDecision = (rows: UpdateRow[]): UpdateRow[] =>
  rows.filter((row) => row.blockedByLocalEdit && !row.forked);
