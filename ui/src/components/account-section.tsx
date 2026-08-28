import { Section, SettingRow } from "@/components/section";
import { Button } from "@/components/ui/button";
import { hasCredential, useAccountStore } from "@/stores/account";

/** Settings → Account: the one place sign-in state lives. Signing in is
 * the device flow — a code, a browser tab, done; signing out kills every
 * credential from that sign-in on the very next request. */
export function AccountSection() {
  const signedIn = useAccountStore((s) => hasCredential(s.account));
  const signingIn = useAccountStore((s) => s.signingIn);
  const userCode = useAccountStore((s) => s.userCode);
  const error = useAccountStore((s) => s.error);
  const signIn = useAccountStore((s) => s.signIn);
  const cancelSignIn = useAccountStore((s) => s.cancelSignIn);
  const signOut = useAccountStore((s) => s.signOut);

  return (
    <Section title="Account">
      <SettingRow
        label="kendex.ai"
        description={
          signedIn
            ? "Signed in. Submitting marketplaces uses this account; the credential lives in your system keychain."
            : "Sign in with GitHub to submit marketplaces to the community directory. Nothing else needs it."
        }
      >
        {signedIn ? (
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
    </Section>
  );
}
