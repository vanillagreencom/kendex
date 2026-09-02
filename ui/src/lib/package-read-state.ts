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
}

const failedNote = ({ status, error }: ReadState): string | null =>
  status === "failed" && error !== null ? packageReadFailedNote(error) : null;

/** Why the package page has no Update when its own reads are the reason, or
 *  null when they are not. Silent while they are pending: the page is still
 *  filling in, and a header note on every open is noise rather than news.
 *
 *  This is not the page's first reason and must never be ranked as one. The
 *  commands behind these reads answer with a refusal for a package that is
 *  not a managed one here as readily as for a read that went wrong — an
 *  undeclared item, a plugin, a path source — and that text is about
 *  declarations and revisions, not about a failure. [`updateOffer`] puts
 *  this behind everything the update read says for that reason: what is left
 *  is a declared package from a repository source whose kind plans one at a
 *  time, which is a read that genuinely did not land. */
export const packageReadNote = (reads: PackageReads): string | null =>
  failedNote(reads.record) ?? failedNote(reads.timeline);
