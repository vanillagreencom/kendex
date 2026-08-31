// The marketplaces this credential has submitted, and what a read of them
// writes. They hang off the account store because a credential's end takes
// them with it; the store owns the guards, and this owns the answer.
import {
  type AccountCallRefused,
  commands,
  type SubmissionRow,
} from "@/bindings";
import { readOrder } from "@/lib/read-state";
import { caught } from "@/lib/settled";

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

/** Submissions reads in the order they were asked for. Only the newest may
 *  land: the tab polls on a timer and a submit that just landed asks again,
 *  so two are routinely out at once and the slower is not the truer one. */
const order = readOrder();

/** Makes the read and writes what it answers, or writes nothing at all
 *  where its answer may not be written.
 *
 *  A read a newer one overtook says nothing, refusal included: both are
 *  about the same credential and the newer one is the later word on it.
 *  Neither does one whose credential changed hands while it was coming,
 *  which is about nobody on screen. `handovers` is read before the call and
 *  again after it, and `refused` decides what a refusal says about the
 *  account itself — the poll shows nothing of its own, so a session that
 *  died between ticks would otherwise go on being polled invisibly.
 *
 *  `write` is taken rather than returned so that it runs in the same
 *  continuation as the guards. Handing an answer back across an await puts
 *  a microtask between the check and the write, and a sign-out landing in
 *  it ends the account after the guards have already let the rows through. */
export const readSubmissions = async (
  handovers: () => number,
  refused: (refusal: AccountCallRefused, since: number) => void,
  write: (fields: Partial<Submissions>) => void,
): Promise<void> => {
  const ticket = order.begin();
  const before = handovers();
  // A transport rejection is a read that failed, not an exception for a
  // `void` caller to drop: it lands as the same refusal shape the server
  // returns, under the same guards.
  const answer = asRefusal(await caught(commands.mineSubmissions()));
  if (!order.lands(ticket) || before !== handovers()) return;
  if (answer.status === "error") refused(answer.error, before);
  write(fromSubmissionsRead(answer));
};

/** What the command answers with, refusal and all. */
type SubmissionsRead =
  | { status: "ok"; data: SubmissionRow[] }
  | { status: "error"; error: AccountCallRefused };

/** A rejected call in the shape the guards and the writer already read. It
 *  says nothing about the credential, only that this read did not happen,
 *  so it takes the `failed` kind rather than `expired`. */
const asRefusal = (
  answer:
    | { status: "ok"; data: SubmissionsRead }
    | { status: "error"; error: string },
): SubmissionsRead =>
  answer.status === "ok"
    ? answer.data
    : { status: "error", error: { kind: "failed", message: answer.error } };

/** What a read's answer writes.
 *
 *  An expiry is news about the credential rather than about the rows, and
 *  the store's own handling of it clears them, so it writes nothing here.
 *  Any other failure leaves the rows already read where they are and says
 *  why they are not current: stale and labelled beats an empty tab, which
 *  reads as a marketplace nobody ever submitted and offers a first submit
 *  over work already in review. */
const fromSubmissionsRead = (answer: SubmissionsRead): Partial<Submissions> => {
  if (answer.status === "ok") {
    return { submissions: answer.data, submissionsError: null };
  }
  return answer.error.kind === "failed"
    ? { submissionsError: answer.error.message }
    : {};
};
