// What a Mine row's submission state reads as. The state itself and the
// rule that decides which one a read leaves are core's: `SubmissionState`
// is generated from it and `mineSubmissionStates` answers with it.
import type { SubmissionState } from "@/bindings";

/** The answer a row has not been given yet, which is the screen before
 *  the first read lands. It shows what a marketplace nobody has submitted
 *  shows, and neither reads as a claim about the server. */
type Unanswered = SubmissionState | null;

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
 *  two is honest: one says the marketplace was never submitted, the other
 *  that it was. */
export const submitLabel = (state: Unanswered): string => {
  if (state?.kind === "submitted") return "Re-submit…";
  return state?.kind === "unknown" ? "Submit…" : "Submit to community…";
};
