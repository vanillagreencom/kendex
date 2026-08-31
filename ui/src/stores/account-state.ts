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
 *  The verdict comes from a call refused under the sign-in (`refused`), not
 *  from the account read, so nothing on the read's own path forgot the
 *  cached identity. An offline answer is that warm cache being served
 *  because the server could not be asked, and it knows strictly less than
 *  the server already said: where the credential was left installed by a
 *  failed removal, it would hand back a name for a sign-in ruled dead and
 *  put Submit in front of the person again.
 *
 *  So only a read that reached the server may overturn the verdict. Signed
 *  out and offline both leave it standing; a signed-in answer is the server
 *  accepting the credential, which is news that outranks it. The cost is a
 *  wrongly-held expiry that the next reachable read clears, which is the
 *  direction a gate on an auth verdict should fail. */
export const keepsExpiry = (held: AccountState, read: AccountState): boolean =>
  held.kind === "expired" &&
  (read.kind === "signed-out" || read.kind === "offline");
