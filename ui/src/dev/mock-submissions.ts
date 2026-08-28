// The submissions side of the Mine tab against canned data: the one row
// the server lists, the refusal every call under the sign-in meets, and
// the browser stand-in for core's ruling over them.
import type {
  SubmissionAsk,
  SubmissionRow,
  SubmissionState,
  SubmissionsRead,
} from "@/bindings";
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

/** The browser stand-in for core's ruling. Core owns it and is tested on
 *  it; this exists only because the mock bridge has no Rust behind it. */
const states = (
  read: SubmissionsRead,
  rows: SubmissionRow[],
  asks: SubmissionAsk[],
): Record<string, SubmissionState> =>
  Object.fromEntries(
    asks.map((ask): [string, SubmissionState] => {
      const listed = ask.repo
        ? rows.find((row) => row.repo === ask.repo)
        : undefined;
      if (listed) return [ask.path, { kind: "submitted", row: listed }];
      return [
        ask.path,
        ask.repo && read === "failed"
          ? { kind: "unknown" }
          : { kind: "not-submitted" },
      ];
    }),
  );

const underSignIn = <T>(call: ExpiringCall, answer: T) => {
  const refused = callRefusal(call);
  return refused ? Promise.reject(refused) : answer;
};

export const submissionHandlers: Record<string, Handler> = {
  mine_submit: (args: { repo: string }) =>
    underSignIn("mine_submit", { repo: args.repo, status: "pending" }),
  mine_submissions: () => underSignIn("mine_submissions", [SUBMISSION]),
  mine_submission_states: (args: {
    read: SubmissionsRead;
    rows: SubmissionRow[];
    asks: SubmissionAsk[];
  }) => states(args.read, args.rows, args.asks),
};
