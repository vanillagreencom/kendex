// What one authored marketplace's submission reads as, out of the rows the
// last read of the caller's submissions left in hand.
import type { SubmissionRow } from "@/bindings";

/** What is known about one marketplace's submission.
 *
 *  `not-submitted` is a positive answer: nothing of this marketplace is
 *  listed, and the read saying so landed. `unknown` is the absence of an
 *  answer: the last read failed or was never made, and what is in hand does
 *  not name this repository. `submitted` carries the row the server listed
 *  it under. */
export type Submission =
  | { kind: "not-submitted" }
  | { kind: "unknown" }
  | { kind: "submitted"; row: SubmissionRow };

/** A submission is keyed by the GitHub repository, so a marketplace with no
 *  remote has nothing the server could have listed and is not submitted
 *  whatever the read did. One the rows name is submitted under the row the
 *  server gave, and stays so under a read that did not land: it is what the
 *  server last said.
 *
 *  Absence answers only where a read landed — rows in hand with nothing
 *  wrong reading them are the whole of what the server lists. Under a
 *  failed or unmade read, absence is `unknown`, or the row would offer a
 *  first submit over work already in review. */
export const submissionFor = (
  rows: SubmissionRow[] | null,
  error: string | null,
  repo: string | null,
): Submission => {
  if (repo === null) return { kind: "not-submitted" };
  const listed = rows?.find((row) => row.repo === repo);
  if (listed) return { kind: "submitted", row: listed };
  return rows !== null && error === null
    ? { kind: "not-submitted" }
    : { kind: "unknown" };
};

/** The answer a row has not been given yet: nothing on the row, the way
 *  not-submitted reads, and no claim in the offer, the way unknown does. */
type Unanswered = Submission | null;

/** What a submission state reads as on the row, or null where the row has
 *  nothing to say about one. */
export const submissionLine = (state: Unanswered): string | null => {
  if (state === null || state.kind === "not-submitted") return null;
  if (state.kind === "unknown") return "Submission status unknown";
  switch (state.row.status) {
    case "pending":
      return "Submitted · in review";
    case "listed":
      return "Listed in the community directory";
    case "needs-changes":
      return state.row.status_reason
        ? `Needs changes — ${state.row.status_reason}`
        : "Needs changes";
    case "delisted":
      return "Delisted";
    default:
      return `Submitted · ${state.row.status}`;
  }
};

/** What the submit button offers. Without an answer neither of the other
 *  two is honest: one claims it was never submitted, the other that it was. */
export const submitLabel = (state: Unanswered): string => {
  if (state === null || state.kind === "unknown") return "Submit…";
  return state.kind === "submitted" ? "Re-submit…" : "Submit to community…";
};
