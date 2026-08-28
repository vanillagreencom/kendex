// The marketplaces this credential has submitted, and what a read of them
// writes. They hang off the account store because a credential's end takes
// them with it; the store owns the guards, and this owns the answer.
import type { AccountCallRefused, SubmissionRow } from "@/bindings";

/** The submissions half of the account store. */
export interface Submissions {
  submissions: SubmissionRow[] | null;
  /** Why the last submissions read failed, or null when one landed. */
  submissionsError: string | null;
}

/** What a credential's end leaves in them: the rows were its, and the
 *  failure explained an account nobody holds any more. */
export const noSubmissions: Submissions = {
  submissions: null,
  submissionsError: null,
};

/** What a read's answer writes.
 *
 *  An expiry is news about the credential rather than about the rows, and
 *  the store's own handling of it clears them, so it writes nothing here.
 *  Any other failure leaves the rows already read where they are and says
 *  why they are not current: stale and labelled beats an empty tab, which
 *  reads as a marketplace nobody ever submitted and offers a first submit
 *  over work already in review. */
export const fromSubmissionsRead = (
  answer:
    | { status: "ok"; data: SubmissionRow[] }
    | { status: "error"; error: AccountCallRefused },
): Partial<Submissions> => {
  if (answer.status === "ok") {
    return { submissions: answer.data, submissionsError: null };
  }
  return answer.error.kind === "failed"
    ? { submissionsError: answer.error.message }
    : {};
};
