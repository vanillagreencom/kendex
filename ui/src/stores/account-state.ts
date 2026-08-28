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
 * the server no longer accepts.
 *
 * The states that hold a credential carry `signIn`, the name core minted
 * for that sign-in. It arrives with the credential and comes back on
 * every read of it, so two answers can be compared for whether they are
 * about the same sign-in. */
export type AccountState =
  | { kind: "loading" }
  | { kind: "signed-out" }
  | { kind: "signed-in"; identity: AccountIdentity | null; signIn: string }
  | { kind: "offline"; identity: AccountIdentity; signIn: string }
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
    ? { kind: "offline", identity: account.identity, signIn: account.signIn }
    : null;

/** Whether two answers are about the same sign-in.
 *
 * Core mints `signIn` when a sign-in is committed, carries it through
 * every token rotation, and replaces it only when another sign-in
 * replaces the credential. So this asks the question the caller actually
 * has, which is whether the credential changed hands, rather than
 * inferring it from the identity: a rename leaves the same credential,
 * and signing in again as the same person leaves a different one under
 * the same name. Neither is visible in what a read says about who the
 * account belongs to. */
export const sameCredential = (
  held: AccountState,
  read: AccountState,
): boolean =>
  hasCredential(held) && hasCredential(read) && held.signIn === read.signIn;
