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
 * The states about a credential carry `signIn`, the name core minted for
 * that sign-in. It arrives with the credential and comes back on every
 * read of it, so two answers can be compared for whether they are about
 * the same one. */
export type AccountState =
  | { kind: "loading" }
  | { kind: "signed-out" }
  | { kind: "signed-in"; identity: AccountIdentity | null; signIn: string }
  | { kind: "offline"; identity: AccountIdentity; signIn: string }
  | { kind: "expired"; signIn: string };

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

/** Which sign-in a state is about, or null when that is not known.
 *
 *  `Credential::sign_in` is `#[serde(default)]` in core so a credential
 *  stored before the field existed still parses instead of signing that
 *  person out, and such a credential reads back with an empty name. Empty
 *  therefore means not-yet-named, never named-empty. It is the absence of
 *  an answer, so it is never equal to another absence: two credentials
 *  that both predate the field are not thereby the same sign-in. */
const signInOf = (account: AccountState): string | null =>
  "signIn" in account && account.signIn !== "" ? account.signIn : null;

/* The two questions below both follow one rule: only a KNOWN difference is
 * a difference, and only a KNOWN match is a match. Neither is the negation
 * of the other, and their unknown branches deliberately disagree, because
 * each takes the answer that is safe for its own question.
 *
 * `sameCredential` asks whether this is the credential already held, and
 * answering yes wrongly keeps another account's rows and lets an obsolete
 * refusal end the wrong sign-in. Unknown must not claim sameness.
 *
 * `differentCredential` asks whether to overturn an expiry the server
 * already ruled on, and answering yes wrongly hands back a submit under a
 * credential known to be dead. Unknown must not overturn it.
 *
 * The cost of unknown falls on a credential stored before core named
 * sign-ins, at most one machine-wide: every read counts as a change of
 * hands, which refetches its rows, until the next sign-in names it. */

/** Whether two answers are known to be about the same sign-in. */
export const sameCredential = (
  held: AccountState,
  read: AccountState,
): boolean => {
  if (!hasCredential(held) || !hasCredential(read)) return false;
  const before = signInOf(held);
  return before !== null && before === signInOf(read);
};

/** Whether two answers are known to be about different sign-ins. */
export const differentCredential = (
  held: AccountState,
  read: AccountState,
): boolean => {
  const before = signInOf(held);
  const now = signInOf(read);
  return before !== null && now !== null && before !== now;
};

/** Whether a settled read leaves a standing expiry where it is.
 *
 *  A read that finds no credential is the refusal's own doing, and one
 *  that could not reach the server knows less than the server already
 *  said: neither takes the verdict back. The exception is an offline
 *  answer about a credential known to be a different one, which some
 *  other process installed; the verdict was about the sign-in it named
 *  and says nothing about this one. */
export const keepsExpiry = (held: AccountState, read: AccountState): boolean =>
  held.kind === "expired" &&
  (read.kind === "signed-out" ||
    (read.kind === "offline" && !differentCredential(held, read)));
