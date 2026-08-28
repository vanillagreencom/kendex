// Account state and the device flow: the store owns the poll timer so a
// closed dialog stops asking, and submissions the Mine rows join on.
//
// Startup makes the one account read; every surface reads `account` from
// here rather than asking again.
import { create } from "zustand";
import { commands, type SubmissionRow } from "@/bindings";

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

/** The states that hold a credential, and so may know a name. */
type WithIdentity = Extract<AccountState, { kind: "signed-in" | "offline" }>;

/** Signed in far enough to submit: an unconfirmed credential still is. */
export const hasCredential = (account: AccountState): account is WithIdentity =>
  account.kind === "signed-in" || account.kind === "offline";

const cachedIdentity = (account: AccountState): AccountIdentity | null =>
  hasCredential(account) ? account.identity : null;

/** What a read of the account answers: the state it settled on, or why it
 * could not be read. */
export type AccountRead = { ok: SettledAccount } | { error: string };

export type ReadAccount = () => Promise<AccountRead>;

/** The command reports whether a credential is stored and nothing more,
 * which settles signed in without a name, or signed out. A name, a
 * credential that could not be confirmed and one the server has rejected
 * all need a backend that has reached the server. */
const fromBridge: ReadAccount = async () => {
  try {
    const status = await commands.accountStatus();
    if (status.status === "error") return { error: status.error };
    return {
      ok: status.data.signedIn
        ? { kind: "signed-in", identity: null }
        : { kind: "signed-out" },
    };
  } catch (error: unknown) {
    // A bridge that throws and a reply that says no are the same answer
    // here: the account could not be read. Letting the throw out would
    // leave the read with nothing recorded and nothing to retry from.
    return { error: String(error) };
  }
};

let readAccount: ReadAccount = fromBridge;

/** Dev only, called by the mock bridge: the harness answers as the states
 * the backend will report once it can reach the server. Null puts the
 * command back. */
export function setAccountReader(read: ReadAccount | null): void {
  readAccount = read ?? fromBridge;
}

interface AccountStore {
  account: AccountState;
  /** The in-flight device flow, when one is showing. */
  userCode: string | null;
  verificationUrl: string | null;
  signingIn: boolean;
  /** Why the device flow or a sign-out failed. The read never writes it:
   *  a person who came back from denying an approval must still be able
   *  to read why nothing happened. */
  error: string | null;
  /** Why the last account read failed, or null when it landed. */
  readError: string | null;
  submissions: SubmissionRow[] | null;

  /** The account read. Startup makes it, a return to the window repeats
   *  it, and a failure surface retries with it. No surface reads on
   *  mount. */
  load: () => Promise<void>;
  /** Starts the device flow and polls until signed, denied or closed. */
  signIn: () => Promise<void>;
  cancelSignIn: () => void;
  signOut: () => Promise<void>;
  loadSubmissions: () => Promise<void>;
}

/** Bumped to abandon a poll loop whose dialog was closed. */
let generation = 0;

/** Bumped where the account changes hands: a credential stored, a
 *  credential dropped. A read still out when that happens is stale, and
 *  the bump is at the change itself, not at the action that begins it. */
let handover = 0;

/** Reads in the order they were asked for. Only the newest may land: two
 *  can be out at once, and the slower one is not the truer one. */
let reads = 0;

const wait = (seconds: number) =>
  new Promise((resolve) => setTimeout(resolve, seconds * 1000));

export const useAccountStore = create<AccountStore>((set, get) => ({
  account: { kind: "loading" },
  userCode: null,
  verificationUrl: null,
  signingIn: false,
  error: null,
  readError: null,
  submissions: null,

  load: async () => {
    reads += 1;
    const mine = reads;
    const before = handover;
    const answer = await readAccount();
    // An older read and a read overtaken by a sign-in or sign-out are the
    // same thing: news about an account that has already moved on.
    if (mine !== reads || before !== handover) return;
    if ("error" in answer) {
      // A read that failed knows nothing new, so it never takes anything
      // away. With an identity already in hand the failure is exactly
      // offline; a credential without a name stays signed in, and a state
      // never read stays unread with the failure to show for it.
      const identity = cachedIdentity(get().account);
      if (identity)
        set({
          account: { kind: "offline", identity },
          readError: answer.error,
        });
      else set({ readError: answer.error });
      return;
    }
    // Submissions belong to the credential. A read that finds it gone
    // leaves what signing out leaves, so nobody's rows outlive them.
    if (hasCredential(answer.ok)) set({ account: answer.ok, readError: null });
    else set({ account: answer.ok, readError: null, submissions: null });
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
        // The approval is proof a credential was stored, so it is recorded
        // before anything else is asked: a read that fails after this must
        // not leave the person looking at a sign-in button. The read that
        // follows is what puts a name to it.
        handover += 1;
        set({
          signingIn: false,
          userCode: null,
          account: { kind: "signed-in", identity: null },
        });
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
    handover += 1;
    set({
      account: { kind: "signed-out" },
      submissions: null,
      error: null,
      readError: null,
    });
  },

  loadSubmissions: async () => {
    if (!hasCredential(get().account)) return;
    const rows = await commands.mineSubmissions();
    if (rows.status === "ok") set({ submissions: rows.data });
  },
}));
