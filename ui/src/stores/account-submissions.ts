// The marketplaces this credential has submitted, and what a read of them
// writes. They hang off the account store because a credential's end takes
// them with it; the store owns the guards, and this owns the answer.
import {
  type AccountCallRefused,
  commands,
  type SubmissionRow,
} from "@/bindings";

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

/** Submissions reads in the order they were asked for. Only the newest
 *  may land: the tab polls on a timer and a submit that just landed asks
 *  again, so two are routinely out at once and the slower is not the
 *  truer one. */
let reads = 0;

/** Makes the read and answers what to write, or null where its answer may
 *  not be written at all.
 *
 *  A read a newer one overtook says nothing, refusal included: both are
 *  about the same credential and the newer one is the later word on it.
 *  Neither does one whose credential changed hands while it was coming,
 *  which is about nobody on screen. `handovers` is read before the call
 *  and again after it, and `refused` decides what a refusal says about
 *  the account itself. */
export const readSubmissions = async (
  handovers: () => number,
  refused: (refusal: AccountCallRefused, since: number) => void,
): Promise<Partial<Submissions> | null> => {
  reads += 1;
  const mine = reads;
  const before = handovers();
  const answer = await commands.mineSubmissions();
  if (mine !== reads || before !== handovers()) return null;
  // The poll shows nothing of its own, so a session that died between
  // ticks would otherwise go on being polled invisibly.
  if (answer.status === "error") refused(answer.error, before);
  return fromSubmissionsRead(answer);
};

/** What a read's answer writes.
 *
 *  An expiry is news about the credential rather than about the rows, and
 *  the store's own handling of it clears them, so it writes nothing here.
 *  Any other failure leaves the rows already read where they are and says
 *  why they are not current: stale and labelled beats an empty tab, which
 *  reads as a marketplace nobody ever submitted and offers a first submit
 *  over work already in review. */
const fromSubmissionsRead = (
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
