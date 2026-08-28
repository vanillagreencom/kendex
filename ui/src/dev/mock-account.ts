// Account state for the mock bridge: the device flow "approves" on the
// second poll, and submissions exist only while signed in.
//
// The real command reports only whether a credential is stored, so the
// states that need a server — a name, an unconfirmed credential, a
// rejected one — are what `?account=` picks on the dev URL.
import type { SettledAccount } from "@/stores/account";
import type { Handler } from "./mock-state";

const IDENTITY = { name: "Ada Lovelace", githubLogin: "ada" };

const SIGNED_OUT: SettledAccount = { kind: "signed-out" };
const SIGNED_IN: SettledAccount = { kind: "signed-in", identity: IDENTITY };

/** The states `?account=` picks from. Signed out is what it falls back to. */
export const MOCK_ACCOUNTS: Record<string, SettledAccount> = {
  "signed-out": SIGNED_OUT,
  "signed-in": SIGNED_IN,
  offline: { kind: "offline", identity: IDENTITY },
  expired: { kind: "expired" },
};

function fromUrl(): SettledAccount {
  if (typeof window === "undefined") return SIGNED_OUT;
  const asked = new URLSearchParams(window.location.search).get("account");
  return (asked ? MOCK_ACCOUNTS[asked] : undefined) ?? SIGNED_OUT;
}

let account = fromUrl();
let polls = 0;

/** The state the bridge answers with, for tests and for the dev URL. */
export function setMockAccount(state: SettledAccount): void {
  account = state;
}

export function isSignedIn(): boolean {
  return account.kind === "signed-in" || account.kind === "offline";
}

export const accountHandlers: Record<string, Handler> = {
  account_status: () => ({
    signedIn: isSignedIn(),
    endpoint: "https://kendex.ai",
    account,
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
