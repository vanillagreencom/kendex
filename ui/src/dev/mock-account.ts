// Account state for the mock bridge: the device flow "approves" on the
// second poll, and submissions exist only while signed in.
//
// One answer, in one place: `served` is what both the store's read and the
// `account_status` handler report, so the harness cannot say two things at
// once. The states that need a server behind them — a name, a credential
// that could not be confirmed, one that was rejected, a read that fails —
// reach the store through its dev reader, which the backend takes over
// once it can reach the server. `?account=` on the dev URL picks one.
import type { AccountStatus } from "@/bindings";
import { hasCredential, type SettledAccount } from "@/stores/account";
import { type AccountRead, setAccountReader } from "@/stores/account-read";
import type { Handler } from "./mock-state";

// The provider's account id is an opaque number the server hands back, not
// a handle. Spelt as one here so nothing in the app can pass by showing it.
const IDENTITY = { name: "Ada Lovelace", githubLogin: "1234567" };

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

/** A read that cannot be made is the fifth thing the store draws, so the
 *  URL names it too. It is not a settled state, so it is not in the map. */
export const UNREADABLE = "unreadable";

const FAILED: AccountRead = { error: "the account could not be read" };

/** Every name `?account=` accepts. */
export const MOCK_ACCOUNT_NAMES = [...Object.keys(MOCK_ACCOUNTS), UNREADABLE];

const named = (asked: string): AccountRead | null => {
  if (asked === UNREADABLE) return FAILED;
  return Object.hasOwn(MOCK_ACCOUNTS, asked)
    ? { ok: MOCK_ACCOUNTS[asked as SettledAccount["kind"]] }
    : null;
};

/** What `?account=` asks the harness to answer. Anything else says so and
 *  signs out. */
export function accountFromUrl(search: string): AccountRead {
  const asked = new URLSearchParams(search).get("account");
  if (asked === null) return { ok: SIGNED_OUT };
  const picked = named(asked);
  if (picked) return picked;
  console.warn(
    `mock has no account '${asked}' — signed out instead. Pick one of ${MOCK_ACCOUNT_NAMES.join(", ")}`,
  );
  return { ok: SIGNED_OUT };
}

let polls = 0;

let served: AccountRead =
  typeof window === "undefined"
    ? { ok: SIGNED_OUT }
    : accountFromUrl(window.location.search);

/** What the harness answers with, for tests and for the dev URL. */
export function setMockAccount(read: AccountRead): void {
  served = read;
}

export function isSignedIn(): boolean {
  return "ok" in served && hasCredential(served.ok);
}

/** Points the store's account read here, so `?account=` picks a state
 *  without a server to ask. */
export function installAccountReader(): void {
  setAccountReader(async () => served);
}

/** `served` in the shape the real command answers. A signed-in credential
 *  always has a name here, as it does from the server; the nameless one
 *  belongs to the moment just after approval, which is the store's own and
 *  is never served from here. */
const wire = (account: SettledAccount): AccountStatus["state"] => {
  switch (account.kind) {
    case "signed-out":
      return { state: "signed-out" };
    case "expired":
      return { state: "expired" };
    case "offline":
      return { state: "offline", identity: account.identity };
    case "signed-in":
      return { state: "signed-in", identity: account.identity ?? IDENTITY };
  }
};

export const accountHandlers: Record<string, Handler> = {
  // The harness points the store at the reader above, so this answers
  // mock-mine's question. It reports from `served` too, so the two can
  // never disagree.
  account_status: () =>
    "error" in served
      ? Promise.reject(served.error)
      : { state: wire(served.ok), endpoint: "https://kendex.ai" },
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
    served = { ok: SIGNED_IN };
    return "signed";
  },
  account_logout: () => {
    served = { ok: SIGNED_OUT };
    return null;
  },
  open_url: () => null,
};
