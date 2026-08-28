// The prose of the two account surfaces: the sidebar's foot and Settings >
// Account. Kept together because the two say the same things about one
// account, and a sentence that drifts between them describes two.
//
// House style is copy.ts's, applied throughout.
// The account row at the foot of the sidebar. Each line says what the last
// read settled on: a credential the server has not confirmed reads as
// offline, and a read that never landed says that rather than picking a
// state for it.
export const ACCOUNT_SIGN_IN_LABEL = "Sign in";
export const ACCOUNT_SIGN_IN_AGAIN_LABEL = "Sign in again";
export const ACCOUNT_EXPIRED_TITLE =
  "kendex.ai no longer accepts this sign-in.";
// A credential is stored but the server has not put a name to it yet, so
// the row shows no handle and claims nothing about who it belongs to.
export const ACCOUNT_SIGNED_IN_LABEL = "Signed in";
export const ACCOUNT_OFFLINE_LABEL = "Offline";
export const ACCOUNT_OFFLINE_TITLE =
  "Signed in as this account when kendex.ai was last reached.";
export const ACCOUNT_UNREADABLE_LABEL = "Couldn't check your account";
export const ACCOUNT_ROW_TITLE = "Open account settings";

// Settings → Account. One row says which of the five things the last read
// found, and the notice under it says why a read did not land — the only
// retry on the page sits there, so a failure is explained in one place
// however the state it interrupted reads.
export const ACCOUNT_SIGNED_IN_NOTE =
  "Signed in to kendex.ai. Submitting marketplaces uses this account; the credential lives in your system keychain.";
export const ACCOUNT_SIGNED_OUT_NOTE =
  "Sign in with GitHub to submit marketplaces to the community directory. Nothing else needs it.";
export const ACCOUNT_SIGN_IN_GITHUB_LABEL = "Sign in with GitHub";
export const ACCOUNT_SIGN_OUT_LABEL = "Sign out";
// The three things "not read yet" can mean. Each says what kendex did, not
// what it found, because it has found nothing.
export const ACCOUNT_CHECKING_NOTE = "Checking whether you are signed in.";
export const ACCOUNT_UNREADABLE_NOTE =
  "kendex could not tell whether you are signed in.";
export const ACCOUNT_UNCHECKED_NOTE =
  "kendex has not checked whether you are signed in.";
export const ACCOUNT_CHECK_LABEL = "Check now";
export const ACCOUNT_RETRY_LABEL = "Try again";
// The device flow, between the browser tab opening and the approval.
export const ACCOUNT_SIGNING_IN_NOTE =
  "Waiting for you to approve this sign-in.";
export const ACCOUNT_CANCEL_SIGN_IN_LABEL = "Cancel";
