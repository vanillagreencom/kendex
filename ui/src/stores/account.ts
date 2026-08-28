// Account state and the device flow: the store owns the poll timer so a
// closed dialog stops asking, and submissions the Mine rows join on.
//
// Startup makes the one account read; every surface reads `account` from
// here rather than asking again.
import { create } from "zustand";
import {
  type AccountCallRefused,
  commands,
  type SubmissionRow,
} from "@/bindings";
import { readAccount } from "./account-read";
import {
  type AccountState,
  asOffline,
  hasCredential,
  keepsExpiry,
  sameCredential,
} from "./account-state";

// The one door every surface already comes to for these.
export {
  type AccountIdentity,
  type AccountState,
  hasCredential,
  type SettledAccount,
} from "./account-state";

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
  /** True while a read is out. A surface that offers the retry needs to
   *  tell a read still on its way from one that was never made: the first
   *  has nothing to ask for again, and the second has never asked. */
  reading: boolean;
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
  /** How many times the account has changed hands. A call going out under
   *  the sign-in reads it first and gives it back to `refused`, which
   *  drops an expiry about a credential nobody holds any more. */
  handovers: () => number;
  /** A call made under the sign-in, read for what its refusal says about
   *  the account. Expiry is the credential ending: the sign-in is dead
   *  server-side and nothing on this machine can revive it, so it leaves
   *  behind what signing out leaves. Every other refusal is news about
   *  that one action and about nothing else, and stays where it was
   *  made.
   *
   *  `since` is the count the call went out under. */
  refused: (refusal: AccountCallRefused, since: number) => void;
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

/** What the end of a credential leaves behind, wherever it ends: the rows
 *  were its, and a read that failed under it explains an account nobody
 *  holds any more. The `handover` bump is the change of hands itself, so
 *  a read still out for the old credential is abandoned. Callers keep
 *  their own guards; only the write is shared. */
const credentialEnded = (
  account: AccountState,
): Pick<AccountStore, "account" | "submissions" | "readError"> => {
  handover += 1;
  return { account, submissions: null, readError: null };
};

const wait = (seconds: number) =>
  new Promise((resolve) => setTimeout(resolve, seconds * 1000));

export const useAccountStore = create<AccountStore>((set, get) => ({
  account: { kind: "loading" },
  userCode: null,
  verificationUrl: null,
  signingIn: false,
  error: null,
  readError: null,
  reading: false,
  submissions: null,

  load: async () => {
    reads += 1;
    const mine = reads;
    const before = handover;
    set({ reading: true });
    const answer = await readAccount();
    // A read a newer one overtook says nothing and clears nothing: the
    // newer read is still out, and the flag is its to lower.
    if (mine !== reads) return;
    set({ reading: false });
    // A read overtaken by a sign-in or sign-out is news about an account
    // that has already moved on.
    if (before !== handover) return;
    if ("error" in answer) {
      // A read that failed knows nothing new, so it never takes anything
      // away. With an identity already in hand the failure is exactly
      // offline; a credential without a name stays signed in, and a state
      // never read stays unread with the failure to show for it.
      const offline = asOffline(get().account);
      const readError = answer.error;
      set(offline ? { account: offline, readError } : { readError });
      return;
    }
    const held = get().account;
    if (keepsExpiry(held, answer.ok)) {
      set(credentialEnded(held));
    } else if (sameCredential(held, answer.ok)) {
      // The same sign-in: named at last, or confirmed again.
      set({ account: answer.ok, readError: null });
    } else {
      // Either the credential is gone, or a read has found one the app
      // did not put there: `kendex login` in a terminal is how that
      // happens. Both are the account changing hands, and submissions
      // belong to the credential, so nobody's rows outlive them.
      set(credentialEnded(answer.ok));
    }
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
      if (polled.data.kind === "signed") {
        // The approval is proof a credential was stored, so it is recorded
        // before anything else is asked: a read that fails after this must
        // not leave the person looking at a sign-in button. The poll
        // answers with the sign-in core minted, so the credential is named
        // from the moment it exists and the read that follows only puts a
        // person's name to it.
        handover += 1;
        set({
          signingIn: false,
          userCode: null,
          account: {
            kind: "signed-in",
            identity: null,
            signIn: polled.data.sign_in,
          },
        });
        await get().load();
        return;
      }
      if (polled.data.kind === "slow-down") interval += 5;
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
    set({ ...credentialEnded({ kind: "signed-out" }), error: null });
  },

  loadSubmissions: async () => {
    if (!hasCredential(get().account)) return;
    const before = handover;
    const rows = await commands.mineSubmissions();
    // The poll shows nothing of its own, so a session that died between
    // ticks would otherwise go on being polled invisibly.
    if (rows.status === "error") {
      get().refused(rows.error, before);
      return;
    }
    // Rows belong to the account they were asked for: ones that changed
    // hands while they were coming belong to nobody on screen.
    if (before !== handover) return;
    set({ submissions: rows.data });
  },

  handovers: () => handover,

  refused: (refusal, since) => {
    if (refusal.kind !== "expired") return;
    // The expiry belongs to the credential the call went out under. One
    // that landed after the account changed hands — a sign-out taken
    // while the call was out, a sign-in finishing behind it — is about a
    // credential nobody holds any more, and ending the account over it
    // would end the one that replaced it.
    if (since !== handover) return;
    // Expiry is a credential ending, so there has to be one to end.
    const held = get().account;
    if (!hasCredential(held)) return;
    // The next read says signed out where the refusal cleared the
    // credential, and meets the same dead sign-in and says expired where
    // it could not. `load` keeps this state through either answer, and
    // the name says which sign-in the verdict was about.
    set(credentialEnded({ kind: "expired", signIn: held.signIn }));
  },
}));
