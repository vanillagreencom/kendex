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

export const cachedIdentity = (
  account: AccountState,
): AccountIdentity | null => (hasCredential(account) ? account.identity : null);

/** Whether a read landed on the credential already held, as far as a read
 *  can tell.
 *
 *  The question is whether the credential changed hands, not whether its
 *  name has arrived. A credential is stored before anything knows who it
 *  belongs to, so a state with no identity at all is transitional and the
 *  read landing here is the one that names it. That is the only wildcard.
 *  Between two identities that have both been read, a null `githubLogin`
 *  is a settled fact about an account whose GitHub link was removed, and
 *  it separates them from a linked one the way any other value would.
 *
 *  What this cannot separate: two read identities that agree on
 *  everything the app is given. A read is told who the account belongs to
 *  and nothing that tells one sign-in for that person from the next, so
 *  the same person signing in again, and two unlinked accounts sharing a
 *  name, both read as the credential already held. Separating those needs
 *  a stable per-sign-in identifier the app is not handed today. */
export const sameAccount = (
  held: AccountState,
  read: AccountState,
): boolean => {
  if (!hasCredential(held) || !hasCredential(read)) return false;
  if (held.identity === null || read.identity === null) return true;
  return (
    held.identity.githubLogin === read.identity.githubLogin &&
    held.identity.name === read.identity.name
  );
};
