// Account state for the mock bridge: the device flow "approves" on the
// second poll, and submissions exist only while signed in.
//
// `account_status` reports what the real command reports, whether a
// credential is stored. The states that need a server behind them — a
// name, a credential that could not be confirmed, one that was rejected —
// come from the store's dev reader, which the backend takes over once it
// can reach the server. `?account=` on the dev URL picks the one to show.
import {
  hasCredential,
  type SettledAccount,
  setAccountReader,
} from "@/stores/account";
import type { Handler } from "./mock-state";

const IDENTITY = { name: "Ada Lovelace", githubLogin: "ada" };

const SIGNED_OUT: SettledAccount = { kind: "signed-out" };
const SIGNED_IN: SettledAccount = { kind: "signed-in", identity: IDENTITY };

/** Every state the store can settle on, and the name `?account=` calls it.
 *  Typed by the state's own tag, so a sixth state has to be added here. */
export const MOCK_ACCOUNTS: Record<SettledAccount["kind"], SettledAccount> = {
  "signed-out": SIGNED_OUT,
  "signed-in": SIGNED_IN,
  offline: { kind: "offline", identity: IDENTITY },
  expired: { kind: "expired" },
};

const named = (asked: string): SettledAccount | null =>
  Object.hasOwn(MOCK_ACCOUNTS, asked)
    ? MOCK_ACCOUNTS[asked as SettledAccount["kind"]]
    : null;

/** The state `?account=` asks for. Anything else says so and signs out. */
export function accountFromUrl(search: string): SettledAccount {
  const asked = new URLSearchParams(search).get("account");
  if (asked === null) return SIGNED_OUT;
  const picked = named(asked);
  if (picked) return picked;
  console.warn(
    `mock has no account state '${asked}' — signed out instead. Pick one of ${Object.keys(MOCK_ACCOUNTS).join(", ")}`,
  );
  return SIGNED_OUT;
}

let polls = 0;

let account =
  typeof window === "undefined"
    ? SIGNED_OUT
    : accountFromUrl(window.location.search);

/** The state the bridge answers with, for tests and for the dev URL. */
export function setMockAccount(state: SettledAccount): void {
  account = state;
}

export function isSignedIn(): boolean {
  return hasCredential(account);
}

/** Points the store's account read here, in place of the command that
 *  cannot answer with a name. */
export function installAccountReader(): void {
  setAccountReader(async () => ({ ok: account }));
}

export const accountHandlers: Record<string, Handler> = {
  account_status: () => ({
    signedIn: isSignedIn(),
    endpoint: "https://kendex.ai",
  }),
  account_login_start: () => {
    polls = 0;
    return {
      deviceCode: "kxd_mock",
      userCode: "ABCD-2345",
      verificationUrl: "https://kendex.ai/device?code=ABCD-2345",
      intervalSeconds: 1,
    };
  },
  account_login_poll: () => {
    polls += 1;
    if (polls < 2) return "pending";
    account = SIGNED_IN;
    return "signed";
  },
  account_logout: () => {
    account = SIGNED_OUT;
    return null;
  },
  open_url: () => null,
};
