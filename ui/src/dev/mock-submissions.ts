// The submissions side of the Mine tab against canned data: the one row
// the server lists, and the refusal every call under the sign-in meets.
import { callRefusal, type ExpiringCall } from "./mock-account";
import type { Handler } from "./mock-state";

/** The one row the mock server lists, for the marketplace whose remote
 *  the Mine fixtures give. */
const SUBMISSION = {
  repo: "jane/team-skills",
  status: "pending",
  status_reason: null,
  head_commit: null,
  indexed_at: null,
};

const underSignIn = <T>(call: ExpiringCall, answer: T) => {
  const refused = callRefusal(call);
  return refused ? Promise.reject(refused) : answer;
};

export const submissionHandlers: Record<string, Handler> = {
  mine_submit: (args: { repo: string }) =>
    underSignIn("mine_submit", { repo: args.repo, status: "pending" }),
  mine_submissions: () => underSignIn("mine_submissions", [SUBMISSION]),
};
