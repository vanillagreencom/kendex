// Account state and the device flow: the store owns the poll timer so a
// closed dialog stops asking, and submissions the Mine rows join on.
//
// Startup makes the one account read; every surface reads `account` from
// here rather than asking again.
import { create } from "zustand";
import { type AccountStatus, commands, type SubmissionRow } from "@/bindings";

/** Who the account belongs to, as the server names them. */
export interface AccountIdentity {
  name: string | null;
  githubLogin: string;
}

/** What is known about the account right now.
 *
 * `signed-in` carries the identity once the backend has one; a credential
 * in the keychain is enough to be signed in before then. `offline` is a
 * credential we know the owner of but could not confirm; `expired` is one
 * the server no longer accepts. */
export type AccountState =
  | { kind: "loading" }
  | { kind: "signed-out" }
  | { kind: "signed-in"; identity: AccountIdentity | null }
  | { kind: "offline"; identity: AccountIdentity }
  | { kind: "expired" };

/** Every state but the one that means "not read yet". */
export type SettledAccount = Exclude<AccountState, { kind: "loading" }>;

/** Signed in far enough to submit: an unconfirmed credential still is. */
export const hasCredential = (account: AccountState): boolean =>
  account.kind === "signed-in" || account.kind === "offline";

const cachedIdentity = (account: AccountState): AccountIdentity | null =>
  account.kind === "signed-in" || account.kind === "offline"
    ? account.identity
    : null;

/** The bridge's answer. The command's own type is the credential check;
 * `account` is what a backend that has reached the server adds, and the
 * dev bridge answers with it so every state can be seen. */
type AccountAnswer = AccountStatus & { account?: SettledAccount };

const settle = (answer: AccountAnswer): SettledAccount =>
  answer.account ??
  (answer.signedIn
    ? { kind: "signed-in", identity: null }
    : { kind: "signed-out" });

interface AccountStore {
  account: AccountState;
  /** The in-flight device flow, when one is showing. */
  userCode: string | null;
  verificationUrl: string | null;
  signingIn: boolean;
  error: string | null;
  submissions: SubmissionRow[] | null;

  /** The one account read. Startup calls it; surfaces subscribe. */
  load: () => Promise<void>;
  /** Starts the device flow and polls until signed, denied or closed. */
  signIn: () => Promise<void>;
  cancelSignIn: () => void;
  signOut: () => Promise<void>;
  loadSubmissions: () => Promise<void>;
}

/** Bumped to abandon a poll loop whose dialog was closed. */
let generation = 0;

const wait = (seconds: number) =>
  new Promise((resolve) => setTimeout(resolve, seconds * 1000));

export const useAccountStore = create<AccountStore>((set, get) => ({
  account: { kind: "loading" },
  userCode: null,
  verificationUrl: null,
  signingIn: false,
  error: null,
  submissions: null,

  load: async () => {
    const status = await commands.accountStatus();
    if (status.status === "error") {
      // A read that failed knows nothing new. With an identity already in
      // hand that is exactly offline; without one there is no state to
      // claim, so the failure is all there is to report.
      const identity = cachedIdentity(get().account);
      if (identity)
        set({ account: { kind: "offline", identity }, error: status.error });
      else set({ error: status.error });
      return;
    }
    set({ account: settle(status.data as AccountAnswer), error: null });
  },

  signIn: async () => {
    generation += 1;
    const mine = generation;
    set({ signingIn: true, error: null });
    const started = await commands.accountLoginStart();
    if (started.status === "error") {
      set({ signingIn: false, error: started.error });
      return;
    }
    set({
      userCode: started.data.userCode,
      verificationUrl: started.data.verificationUrl,
    });
    void commands.openUrl(started.data.verificationUrl);
    let interval = Math.max(1, started.data.intervalSeconds);
    while (generation === mine) {
      await wait(interval);
      if (generation !== mine) return;
      const polled = await commands.accountLoginPoll(started.data.deviceCode);
      if (generation !== mine) return;
      if (polled.status === "error") {
        set({ signingIn: false, userCode: null, error: polled.error });
        return;
      }
      if (polled.data === "signed") {
        set({ signingIn: false, userCode: null });
        // The approval says a credential exists; the read says who it
        // belongs to.
        await get().load();
        return;
      }
      if (polled.data === "slow-down") interval += 5;
    }
  },

  cancelSignIn: () => {
    generation += 1;
    set({ signingIn: false, userCode: null, verificationUrl: null });
  },

  signOut: async () => {
    const out = await commands.accountLogout();
    if (out.status === "error") {
      set({ error: out.error });
      return;
    }
    set({ account: { kind: "signed-out" }, submissions: null, error: null });
  },

  loadSubmissions: async () => {
    if (!hasCredential(get().account)) return;
    const rows = await commands.mineSubmissions();
    if (rows.status === "ok") set({ submissions: rows.data });
  },
}));
