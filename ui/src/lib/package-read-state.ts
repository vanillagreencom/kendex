// How the package page's own reads of one package went, and what the page
// says when one of them did not land: the header for the two reads Update
// turns on, the Overview's file list for the third. The update read's side
// of the header's question is `updates-read-state.ts` [`packageUpdateNote`];
// `versions.ts` [`updateOffer`] ranks the two into the one string the header
// renders.
import { packageFilesReadFailedNote } from "@/lib/copy";
import { packageReadFailedNote } from "@/lib/copy-updates";
import type { ReadState } from "@/lib/read-state";

/** How the page's own three reads went. The two that gate Update are kept
 *  apart rather than folded into one answer: either one failing is a
 *  package this page could not read, and the timeline's failing on its own
 *  is separately why "there is nothing newer to move to" cannot be read off
 *  an empty version list. The file list gates nothing — no Update ever
 *  turned on it, and folding it into the header would withhold the button
 *  over a read it does not depend on — but it is a read all the same, and a
 *  refusal there is not a package that ships no files. */
export interface PackageReads {
  /** The record that says held or following. */
  record: ReadState;
  /** The timeline Update moves along. */
  timeline: ReadState;
  /** The files the Overview lists. */
  files: ReadState;
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

/** What the Overview's file list says instead of files when its read did
 *  not land, or null while it is pending or once it landed. Its own note,
 *  not the header's: the header's says why there is no Update, and this read
 *  never withholds one. */
export const packageFilesNote = ({ files }: PackageReads): string | null =>
  files.status === "failed" && files.error !== null
    ? packageFilesReadFailedNote(files.error)
    : null;
