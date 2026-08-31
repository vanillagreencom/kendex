// What an account is, and what can be told about one by looking at it.
// The store that holds one, reads it, and moves it is `account.ts`.

/** Who the account belongs to, as the server names them. The linked
 * GitHub account is null once it has been unlinked. */
export interface AccountIdentity {
  name: string;
  githubLogin: string | null;
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

/** The same credential, no longer confirmed: what a read that failed
 *  leaves when it already knew who holds it. Null when there is nothing
 *  to go offline with, which is a credential whose name has not been read
 *  yet, or no credential at all. */
export const asOffline = (account: AccountState): SettledAccount | null =>
  hasCredential(account) && account.identity
    ? { kind: "offline", identity: account.identity }
    : null;

/** Whether a settled read leaves a standing expiry where it is.
 *
 *  Only a signed-out answer does. `me::load` forgets the cached identity on
 *  every `SignInExpired`, including the arm where the store would not give
 *  the credential up, so no later read can serve a cached name: it either
 *  finds nothing and says signed out, or reaches the server and answers for
 *  whatever credential is really there. Signed out is therefore the one
 *  answer that says nothing new, and every other is news the verdict was
 *  never about. */
export const keepsExpiry = (held: AccountState, read: AccountState): boolean =>
  held.kind === "expired" && read.kind === "signed-out";
