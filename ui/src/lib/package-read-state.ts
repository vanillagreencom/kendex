// How the package page's own reads of one package went, and what the page
// says when one of them did not land: the header for the two reads Update
// turns on, the Files tab and the Overview for the two that open the
// source. The update read's side of the header's question is
// `updates-read-state.ts` [`packageUpdateNote`]; `versions.ts`
// [`updateOffer`] ranks the two into the one string the header renders.
import type { SourceReadRefused } from "@/bindings";
import { packageFilesReadFailedNote } from "@/lib/copy";
import {
  packageReadFailedNote,
  sourceUnfetchedFilesNote,
  sourceUnfetchedNote,
  sourceUnfetchedReadmeNote,
} from "@/lib/copy-updates";
import { READ_LANDED, type ReadState, readFailed } from "@/lib/read-state";
import { isShapedRefusal, refusalWords } from "@/lib/refusal";
import { NO_REASON_GIVEN } from "@/lib/settled";

/** How a read that opens the package's source went: the read itself, and
 *  the source core said no fetch has downloaded yet, or null. A read that
 *  answered that landed — core read the manifest and the mirror and said
 *  what it found — and left nothing to draw because there is nothing to
 *  read until a refresh. Kept apart from the read so that answer is
 *  neither a read that failed, which offers a re-read that answers the
 *  same, nor a package with nothing in it, which says nothing. */
export interface SourceRead {
  read: ReadState;
  unfetched: string | null;
}

/** No read has answered yet. */
export const SOURCE_READ_PENDING: SourceRead = {
  read: { status: "pending", error: null },
  unfetched: null,
};

/** The read landed on a source with a mirror to read. */
export const SOURCE_READ_LANDED: SourceRead = {
  read: READ_LANDED,
  unfetched: null,
};

/** How the page's own four reads went. The two that gate Update are kept
 *  apart rather than folded into one answer: either one failing is a
 *  package this page could not read, and the timeline's failing on its own
 *  is separately why "there is nothing newer to move to" cannot be read off
 *  an empty version list. The file list and the README gate nothing — no
 *  Update ever turned on them, and folding them into the header would
 *  withhold the button over reads it does not depend on — but they are
 *  reads all the same, and a refusal there is not a package that ships no
 *  files or carries no README. */
export interface PackageReads {
  /** The record that says held or following. */
  record: ReadState;
  /** The timeline Update moves along. */
  timeline: SourceRead;
  /** The files the Files tab lists. */
  files: SourceRead;
  /** The README the Overview is. */
  readme: SourceRead;
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
  failedNote(reads.record) ?? failedNote(reads.timeline.read);

/** What a read of the package's source leaves behind: how it went, and the
 *  source no fetch has downloaded where that was core's answer. One judge
 *  for the timeline, the files and the README, which all open the same
 *  declaration: a second copy of this test is the header and a tab
 *  disagreeing about whether the same source has been downloaded. A
 *  transport failure arrives with no shape around it and lands as a read
 *  that failed, the way `refusal.ts` says every folded message must. */
export const sourceReadOf = (
  response:
    | { status: "ok" }
    | { status: "error"; error: SourceReadRefused | string },
): SourceRead => {
  if (response.status === "ok") return SOURCE_READ_LANDED;
  const { error } = response;
  if (isShapedRefusal(error) && error.kind === "source-pending") {
    return { read: READ_LANDED, unfetched: error.source };
  }
  return {
    read: readFailed(refusalWords(error) ?? NO_REASON_GIVEN),
    unfetched: null,
  };
};

/** What the header says while the package's source is unfetched, or null.
 *  Where this ranks, and why it carries no Try again, is `versions.ts`
 *  [`updateOffer`]'s. */
export const unfetchedNote = (reads: PackageReads): string | null =>
  reads.timeline.unfetched === null
    ? null
    : sourceUnfetchedNote(reads.timeline.unfetched);

/** What a tab says in place of the source's content when its read did not
 *  land it. The source no fetch has downloaded is an answer, drawn as a
 *  neutral line with no Try again, since asking again answers the same; a
 *  read that failed is drawn as one, with the reason it came back with and
 *  the read offered again. */
export type SourceReadNote =
  | { is: "not-downloaded"; line: string }
  | { is: "failed"; line: string };

const sourceReadNote = (
  { read, unfetched }: SourceRead,
  notDownloaded: (source: string) => string,
  failed: (reason: string) => string,
): SourceReadNote | null => {
  if (unfetched !== null) {
    return { is: "not-downloaded", line: notDownloaded(unfetched) };
  }
  if (read.status === "failed" && read.error !== null) {
    return { is: "failed", line: failed(read.error) };
  }
  return null;
};

/** What the file list says instead of files when its read did not land
 *  them, or null while it is pending or once it landed. Its own note, not
 *  the header's: the header's says why there is no Update, and this read
 *  never withholds one. The failed line carries its own headline.
 *
 *  Takes the read itself rather than the page's four, because null here
 *  covers a read still on its way as well as one that landed, and the
 *  surface needs the state to tell those apart. */
export const packageFilesNote = (files: SourceRead): SourceReadNote | null =>
  sourceReadNote(files, sourceUnfetchedFilesNote, packageFilesReadFailedNote);

/** What the Overview says instead of the README when its read did not land
 *  it, or null while it is pending or once it landed. The failed line is
 *  the reason alone, which the Overview draws under the file pane's own
 *  headline. */
export const packageReadmeNote = (readme: SourceRead): SourceReadNote | null =>
  sourceReadNote(readme, sourceUnfetchedReadmeNote, (reason) => reason);

/** A refusal of one file's read as one line, for the pane that draws every
 *  refusal in its single failure slot. The pane is mounted only under a
 *  file list that landed, which lands only from a source with a mirror, so
 *  no producer reaches it in the not-downloaded state; the kind is read
 *  through the same judge all the same, so a page never has to recognise
 *  that state from words. */
export const packageFileRefusalLine = (
  refusal: SourceReadRefused | string,
): string =>
  isShapedRefusal(refusal) && refusal.kind === "source-pending"
    ? sourceUnfetchedFilesNote(refusal.source)
    : (refusalWords(refusal) ?? NO_REASON_GIVEN);
