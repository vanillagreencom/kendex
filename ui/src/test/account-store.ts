// The account store's test harness: the wire answer, the reader seam, the
// named fixtures, and the reset, shared by the files that exercise it.
//
// Each test file installs its own `vi.mock("@/bindings", ...)`; the
// helpers here read through whichever mock the importing file set up.
import { vi } from "vitest";
import {
  type AccountReadFailed,
  type AccountStatus,
  commands,
} from "@/bindings";
import { type SettledAccount, useAccountStore } from "@/stores/account";
import { setAccountReader } from "@/stores/account-read";

export const ADA = { name: "Ada Lovelace", githubLogin: "ada" };
export const BOB = { name: "Bob", githubLogin: "bob" };

/** What the real command answers: the state the backend settled on. */
export const answers = (state: AccountStatus["state"]) =>
  vi.mocked(commands.accountStatus).mockResolvedValue({
    status: "ok",
    data: { state, endpoint: "https://kendex.ai" },
  } as Awaited<ReturnType<typeof commands.accountStatus>>);

/** What the command answers when the read did not land. The default is a
 *  refusal on this machine, which is the failure that says nothing about
 *  kendex.ai; pass `"unreachable"` for the directory not answering. */
export const unreadable = (
  why = "keychain locked",
  kind: AccountReadFailed["kind"] = "local",
) =>
  vi.mocked(commands.accountStatus).mockResolvedValue({
    status: "error",
    error: { kind, message: why },
  } as Awaited<ReturnType<typeof commands.accountStatus>>);

/** What a backend that has reached the server answers with. */
export const serves = (account: SettledAccount) =>
  setAccountReader(async () => ({ ok: account }));

export const load = () => useAccountStore.getState().load();
export const account = () => useAccountStore.getState().account;

export const fresh = () =>
  useAccountStore.setState({
    account: { kind: "loading" },
    error: null,
    readError: null,
    submissions: null,
    submissionsError: null,
    signingIn: false,
    userCode: null,
    reading: false,
  });

/** One submission row, so a test can watch rows survive or go with the
 *  credential that owned them. */
export const ROW = {
  repo: "ada/team-skills",
  status: "pending",
  status_reason: null,
  head_commit: null,
  indexed_at: null,
};
