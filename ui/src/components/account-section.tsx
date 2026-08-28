import { Section, SettingRow } from "@/components/section";
import { Button } from "@/components/ui/button";
import { hasCredential, useAccountStore } from "@/stores/account";

/** What the row says while no read has landed. A read still out, a read
 *  that failed and a read never made are three different things, and the
 *  button is dead only for the first. */
function beforeAnyAnswer(reading: boolean, readError: string | null) {
  if (reading)
    return { note: "Checking whether you are signed in.", action: "Checking…" };
  if (readError)
    return {
      note: "kendex could not tell whether you are signed in.",
      action: "Try again",
    };
  return {
    note: "kendex has not checked whether you are signed in.",
    action: "Check now",
  };
}

/** Settings → Account: the one place sign-in state lives. Signing in is
 * the device flow — a code, a browser tab, done; signing out kills every
 * credential from that sign-in on the very next request. */
export function AccountSection() {
  const unread = useAccountStore((s) => s.account.kind === "loading");
  const signedIn = useAccountStore((s) => hasCredential(s.account));
  const signingIn = useAccountStore((s) => s.signingIn);
  const userCode = useAccountStore((s) => s.userCode);
  const error = useAccountStore((s) => s.error);
  const readError = useAccountStore((s) => s.readError);
  const reading = useAccountStore((s) => s.reading);
  const signIn = useAccountStore((s) => s.signIn);
  const cancelSignIn = useAccountStore((s) => s.cancelSignIn);
  const signOut = useAccountStore((s) => s.signOut);
  const load = useAccountStore((s) => s.load);
  const unanswered = beforeAnyAnswer(reading, readError);

  return (
    <Section title="Account">
      <SettingRow
        label="kendex.ai"
        description={
          unread
            ? unanswered.note
            : signedIn
              ? "Signed in. Submitting marketplaces uses this account; the credential lives in your system keychain."
              : "Sign in with GitHub to submit marketplaces to the community directory. Nothing else needs it."
        }
      >
        {/* A read that never landed knows neither answer, so the row asks
            for the read again instead of offering a sign-in that may
            already have happened. Only a read still out disables it. */}
        {unread ? (
          <Button
            variant="outline"
            disabled={reading}
            onClick={() => void load()}
          >
            {unanswered.action}
          </Button>
        ) : signedIn ? (
          <Button variant="outline" onClick={() => void signOut()}>
            Sign out
          </Button>
        ) : signingIn ? (
          <Button variant="outline" onClick={cancelSignIn}>
            Cancel
          </Button>
        ) : (
          <Button onClick={() => void signIn()}>Sign in with GitHub</Button>
        )}
      </SettingRow>
      {signingIn && userCode ? (
        <p className="text-sm text-muted-foreground">
          A kendex.ai page just opened with the code{" "}
          <span className="font-mono font-medium">{userCode}</span> — approve it
          there and this page updates on its own.
        </p>
      ) : null}
      {error ? (
        <p className="text-sm text-critical" role="alert">
          {error}
        </p>
      ) : null}
      {readError ? (
        <p className="text-sm text-critical" role="alert">
          {readError}
        </p>
      ) : null}
    </Section>
  );
}
