// Account state and the device flow: the store owns the poll timer so a
// closed dialog stops asking, and submissions the Mine rows join on.
//
// Startup makes the one account read; every surface reads `account` from
// here rather than asking again.
import { create } from "zustand";
import { type AccountCallRefused, commands } from "@/bindings";
import { readAccount } from "./account-read";
import {
  type AccountState,
  asOffline,
  hasCredential,
  keepsExpiry,
} from "./account-state";
import {
  noSubmissions,
  readSubmissions,
  type Submissions,
} from "./account-submissions";

// The one door every surface already comes to for these.
export {
  type AccountIdentity,
  type AccountState,
  hasCredential,
  type SettledAccount,
} from "./account-state";

interface AccountStore extends Submissions {
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

  /** The account read. Startup makes it, a return to the window repeats
   *  it, and a failure surface retries with it. No surface reads on
   *  mount. */
  load: () => Promise<void>;
  /** Starts the device flow and polls until signed, denied or closed. */
  signIn: () => Promise<void>;
  cancelSignIn: () => void;
  signOut: () => Promise<void>;
  loadSubmissions: () => Promise<void>;
  /** A call made under the sign-in, read for what its refusal says about
   *  the account. Expiry is the credential ending: the sign-in is dead
   *  server-side and nothing on this machine can revive it, so it leaves
   *  behind what signing out leaves. Every other refusal is news about
   *  that one action and about nothing else, and stays where it was
   *  made. */
  refused: (refusal: AccountCallRefused) => void;
}

/** Bumped to abandon a poll loop whose dialog was closed. */
let generation = 0;

/** What the end of a credential leaves behind, wherever it ends: the rows
 *  were its, and a read that failed under it explains an account nobody
 *  holds any more. */
const credentialEnded = (account: AccountState) => ({
  account,
  readError: null,
  ...noSubmissions,
});

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
  ...noSubmissions,

  load: async () => {
    set({ reading: true });
    const answer = await readAccount();
    set({ reading: false });
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
    // The refusal that expired the credential removed it, so the read that
    // follows finds nothing and does not get to unsay the verdict.
    if (keepsExpiry(held, answer.ok)) {
      set({ readError: null });
      return;
    }
    // A credential that is gone takes the rows with it: submissions belong
    // to the credential that made them.
    set(
      hasCredential(answer.ok)
        ? { account: answer.ok, readError: null }
        : credentialEnded(answer.ok),
    );
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
        // not leave the person looking at a sign-in button.
        set({
          signingIn: false,
          userCode: null,
          account: { kind: "signed-in", identity: null },
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
    set(await readSubmissions(get().refused));
  },

  refused: (refusal) => {
    if (refusal.kind !== "expired") return;
    // Expiry is a credential ending, so there has to be one to end.
    if (!hasCredential(get().account)) return;
    // The next read says signed out where the refusal cleared the
    // credential; `load` keeps this state through that answer.
    set(credentialEnded({ kind: "expired" }));
  },
}));
