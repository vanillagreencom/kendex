// What a Mine row knows about its own submission, and what that reads as.
// Three answers, not two: a marketplace the server never listed and one
// the app could not ask about must not read alike, or work already in
// review is offered a first submit.
import type { SubmissionRow } from "@/bindings";

/** What is known about one marketplace's submission. `unknown` is the
 *  absence of an answer, which is what a submissions read that failed
 *  leaves behind. */
export type SubmissionState =
  | { kind: "none" }
  | { kind: "unknown" }
  | { kind: "submitted"; row: SubmissionRow };

/** What the rows in hand say about one marketplace. A row already read
 *  answers for itself even under a standing failure: it is what the
 *  server last said, and the tab labels it stale rather than hiding it.
 *  Absence is only an answer while the reads land, so a failure turns it
 *  into no answer at all. */
export const submissionFor = (
  rows: SubmissionRow[] | null,
  failed: boolean,
  repo: string | null,
): SubmissionState => {
  // A submission is keyed by the GitHub repository, so a marketplace with
  // no remote has nothing the server could have listed: not submitted is
  // the whole answer, and no failure makes it less certain.
  if (repo === null) return { kind: "none" };
  const found = rows?.find((candidate) => candidate.repo === repo);
  if (found) return { kind: "submitted", row: found };
  return failed ? { kind: "unknown" } : { kind: "none" };
};

/** What a submission state reads as on the row, or null where the row has
 *  nothing to say about one. */
export const submissionLine = (state: SubmissionState): string | null => {
  if (state.kind === "none") return null;
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
 *  two is honest: one says the marketplace was never submitted, the other
 *  that it was. */
export const submitLabel = (state: SubmissionState): string => {
  if (state.kind === "submitted") return "Re-submit…";
  return state.kind === "unknown" ? "Submit…" : "Submit to community…";
};
