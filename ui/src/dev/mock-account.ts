// Account state for the mock bridge: the device flow "approves" on the
// second poll, and submissions exist only while signed in.
//
// One answer, in one place: `served` is what both the store's read and the
// `account_status` handler report, so the harness cannot say two things at
// once. The states that need a server behind them — a name, a credential
// that could not be confirmed, one that was rejected, a read that fails —
// reach the store through its dev reader, which the backend takes over
// once it can reach the server. `?account=` on the dev URL picks one.
import type { AccountCallRefused, AccountStatus } from "@/bindings";
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

/** The whole sentence a real expiry carries, remedy included. */
const EXPIRED =
  "your sign-in has expired (invalid_grant) — run `kendex login` again";

/** The calls that go out under the stored sign-in, by the name the bridge
 *  dispatches on. */
export const EXPIRING_CALLS = ["mine_submit", "mine_submissions"] as const;

export type ExpiringCall = (typeof EXPIRING_CALLS)[number];

/** Which call `?expire=` puts the expiry on, or null for none.
 *
 *  It names one call rather than arming them all because the Mine tab
 *  polls its submissions on mount: an expiry both calls answer to would
 *  end the account before anyone could press Submit, and the submit
 *  meeting one is the flow this exists to show. The read and the calls
 *  answer separately for the same reason. The server can refuse a
 *  credential this machine still holds, and `?account=expired` takes the
 *  Submit away instead of letting it meet the refusal. */
export function expiringCallFromUrl(search: string): ExpiringCall | null {
  const asked = new URLSearchParams(search).get("expire");
  if (asked === null) return null;
  const named = EXPIRING_CALLS.find((call) => call === asked);
  if (named) return named;
  console.warn(
    `mock cannot expire '${asked}' — nothing armed. Pick one of ${EXPIRING_CALLS.join(", ")}`,
  );
  return null;
}

/** What an outage answers with: the sentence kendex.ai's client writes
 *  when it could not reach the server at all. */
const UNREACHABLE = "kendex.ai could not be reached — check your connection";

/** Whether `?unreachable` is on the dev URL, which makes every call under
 *  the sign-in fail the way an outage does. It is the state the Mine tab
 *  labels its rows unknown for, and no `?account=` state produces it: the
 *  credential is fine, the server is not. */
export function unreachableFromUrl(search: string): boolean {
  return new URLSearchParams(search).has("unreachable");
}

let unreachable =
  typeof window !== "undefined" && unreachableFromUrl(window.location.search);

/** Arms the outage, for tests and for the dev URL. */
export function setUnreachable(on: boolean): void {
  unreachable = on;
}

let expiring: ExpiringCall | null =
  typeof window === "undefined"
    ? null
    : expiringCallFromUrl(window.location.search);

/** Arms the expiry on one call, for tests and for the dev URL. */
export function setExpiringCall(call: ExpiringCall | null): void {
  expiring = call;
}

/** Why a call made under the sign-in refuses, or null when it goes
 *  through. Tagged as the command answers, so a consumer reading
 *  `.message` gets the sentence rather than undefined.
 *
 *  Meeting the expiry is what ends the sign-in, so the credential goes
 *  with it and the read that follows says signed out, as it does in the
 *  app. The scenario is spent in the same moment: signing in again comes
 *  back to a working call rather than expiring for the rest of the
 *  session. */
export function callRefusal(call: ExpiringCall): AccountCallRefused | null {
  // An outage is not the credential's doing, so it outlives no scenario
  // and ends no sign-in: every call keeps failing until it is turned off.
  if (unreachable) return { kind: "failed", message: UNREACHABLE };
  if (expiring === call) {
    expiring = null;
    served = { ok: SIGNED_OUT };
    return { kind: "expired", message: EXPIRED };
  }
  if (!isSignedIn()) return { kind: "failed", message: "sign in first" };
  return null;
}

/** Points the store's account read here, so `?account=` picks a state
 *  without a server to ask. */
export function installAccountReader(): void {
  setAccountReader(async () => served);
}

/** `served` in the shape the real command answers. */
const wire = (account: SettledAccount): AccountStatus["state"] => {
  switch (account.kind) {
    case "signed-out":
      return { state: "signed-out" };
    case "expired":
      return { state: "expired" };
    case "offline":
      return { state: "offline", identity: account.identity };
    case "signed-in":
      return {
        state: "signed-in",
        identity: account.identity ?? IDENTITY,
      };
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
    if (polls < 2) return { kind: "pending" };
    // The credential the approval stores: the read that follows answers
    // with it.
    served = { ok: SIGNED_IN };
    return { kind: "signed" };
  },
  account_logout: () => {
    served = { ok: SIGNED_OUT };
    return null;
  },
  open_url: () => null,
};
