// How the package page's own reads of one package went, and what the header
// says when one of them did not land. The update read's side of that same
// question is `updates-read-state.ts` [`packageUpdateNote`]; `versions.ts`
// [`updateOffer`] ranks the two into the one string the header renders.
import { packageReadFailedNote } from "@/lib/copy-updates";
import type { ReadState } from "@/lib/read-state";

/** How the page's own two gating reads went. Kept apart rather than folded
 *  into one answer: either one failing is a package this page could not
 *  read, and the timeline's failing on its own is separately why "there is
 *  nothing newer to move to" cannot be read off an empty version list. The
 *  file list is in neither — no Update ever turned on it, and folding it in
 *  would withhold the button over a read it does not depend on. */
export interface PackageReads {
  /** The record that says held or following. */
  record: ReadState;
  /** The timeline Update moves along. */
  timeline: ReadState;
  /** Whether the newest of these reads is still out. The last answer stays
   *  on screen while it runs — a failure that has not been disproved is
   *  still the truth about this package — so this is what says the reason
   *  under it is being asked again rather than standing unattended. */
  reading: boolean;
}

const failedNote = ({ status, error }: ReadState): string | null =>
  status === "failed" && error !== null ? packageReadFailedNote(error) : null;

/** Why the package page has no Update when its own reads are the reason, or
 *  null when they are not. Silent while they are pending: the page is still
 *  filling in, and a header note on every open is noise rather than news.
 *
 *  Never the page's first reason. `versions.ts` [`updateOffer`] owns where
 *  this ranks and why. */
export const packageReadNote = (reads: PackageReads): string | null =>
  failedNote(reads.record) ?? failedNote(reads.timeline);
