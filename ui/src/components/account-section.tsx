import type { ReactNode } from "react";
import { AccountAvatar, displayName } from "@/components/account-avatar";
import { Section, SettingRow } from "@/components/section";
import { Button } from "@/components/ui/button";
import {
  ACCOUNT_CANCEL_SIGN_IN_LABEL,
  ACCOUNT_CHECK_LABEL,
  ACCOUNT_CHECKING_NOTE,
  ACCOUNT_EXPIRED_TITLE,
  ACCOUNT_OFFLINE_LABEL,
  ACCOUNT_OFFLINE_TITLE,
  ACCOUNT_RETRY_LABEL,
  ACCOUNT_SIGN_IN_AGAIN_LABEL,
  ACCOUNT_SIGN_IN_GITHUB_LABEL,
  ACCOUNT_SIGN_OUT_LABEL,
  ACCOUNT_SIGNED_IN_LABEL,
  ACCOUNT_SIGNED_IN_NOTE,
  ACCOUNT_SIGNED_OUT_NOTE,
  ACCOUNT_SIGNING_IN_NOTE,
  ACCOUNT_UNCHECKED_NOTE,
  ACCOUNT_UNREADABLE_LABEL,
  ACCOUNT_UNREADABLE_NOTE,
} from "@/lib/copy-account";
import {
  type AccountIdentity,
  type AccountState,
  useAccountStore,
} from "@/stores/account";

/** The service the account belongs to, for the states that know no person
 *  to name instead. */
const ENDPOINT = "kendex.ai";

/** What the store offers this section. Gathered into one shape so the row
 *  below stays a function of the state rather than of the store. */
interface Acts {
  signIn: () => void;
  signOut: () => void;
  load: () => void;
}

/** Whose account it is: the letter and the name, or "Signed in" where the
 *  server holds a credential it has not yet put a name to. */
function Whose({
  identity,
  marker,
}: {
  identity: AccountIdentity | null;
  marker?: string;
}) {
  return (
    <span className="flex items-center gap-2">
      <AccountAvatar identity={identity} className="size-6 text-[11px]" />
      {displayName(identity) || ACCOUNT_SIGNED_IN_LABEL}
      {marker ? (
        <span className="text-xs font-normal text-muted-foreground">
          {marker}
        </span>
      ) : null}
    </span>
  );
}

/** What the section says before any read has landed.
 *
 *  A read still out, a read that failed and a read never made are three
 *  different things. Only the last is worth asking for: the first is
 *  already on its way, and the second is retried from the notice that
 *  carries its reason, so neither offers a button here. */
function beforeAnyAnswer(
  reading: boolean,
  readError: string | null,
  load: () => void,
): ReactNode {
  if (reading)
    return <SettingRow label={ENDPOINT} description={ACCOUNT_CHECKING_NOTE} />;
  if (readError !== null)
    return (
      <SettingRow label={ENDPOINT} description={ACCOUNT_UNREADABLE_NOTE} />
    );
  return (
    <SettingRow label={ENDPOINT} description={ACCOUNT_UNCHECKED_NOTE}>
      <Button variant="outline" onClick={load}>
        {ACCOUNT_CHECK_LABEL}
      </Button>
    </SettingRow>
  );
}

/** The one row for the account, drawn from the state alone.
 *
 *  The five states are five rows: a credential in the keychain is not a
 *  confirmed sign-in, so an unconfirmed one reads as offline and one the
 *  server has rejected asks to sign in again rather than showing either a
 *  sign-out or a plain signed-out row. */
function accountRow(
  account: AccountState,
  reading: boolean,
  readError: string | null,
  act: Acts,
): ReactNode {
  if (account.kind === "loading")
    return beforeAnyAnswer(reading, readError, act.load);

  switch (account.kind) {
    case "signed-out":
      return (
        <SettingRow label={ENDPOINT} description={ACCOUNT_SIGNED_OUT_NOTE}>
          <Button onClick={act.signIn}>{ACCOUNT_SIGN_IN_GITHUB_LABEL}</Button>
        </SettingRow>
      );
    case "expired":
      return (
        <SettingRow label={ENDPOINT} description={ACCOUNT_EXPIRED_TITLE}>
          <Button onClick={act.signIn}>{ACCOUNT_SIGN_IN_AGAIN_LABEL}</Button>
        </SettingRow>
      );
    case "signed-in":
      return (
        <SettingRow
          label={<Whose identity={account.identity} />}
          description={ACCOUNT_SIGNED_IN_NOTE}
        >
          <Button variant="outline" onClick={act.signOut}>
            {ACCOUNT_SIGN_OUT_LABEL}
          </Button>
        </SettingRow>
      );
    case "offline":
      // The credential is still ours to drop, so signing out stays offered:
      // it clears what this machine holds, and the server hears about it on
      // the next request either way.
      return (
        <SettingRow
          label={
            <Whose identity={account.identity} marker={ACCOUNT_OFFLINE_LABEL} />
          }
          description={ACCOUNT_OFFLINE_TITLE}
        >
          <Button variant="outline" onClick={act.signOut}>
            {ACCOUNT_SIGN_OUT_LABEL}
          </Button>
        </SettingRow>
      );
  }

  // A sixth account state has to be drawn above before this compiles.
  const undrawn: never = account;
  return undrawn;
}

/** Settings → Account: the one place sign-in state lives, and the one place
 * a failed account read is explained.
 *
 * Signing in is the device flow — a code, a browser tab, done; signing out
 * kills every credential from that sign-in on the very next request.
 *
 * The sidebar row says which state the last read settled on and opens this
 * page. The reason a read did not land, and the retry for it, live here
 * alone: two surfaces explaining one failure would drift, and only this one
 * has the room to say it in words.
 */
export function AccountSection() {
  const account = useAccountStore((s) => s.account);
  const reading = useAccountStore((s) => s.reading);
  const readError = useAccountStore((s) => s.readError);
  const signingIn = useAccountStore((s) => s.signingIn);
  const userCode = useAccountStore((s) => s.userCode);
  const error = useAccountStore((s) => s.error);
  const signIn = useAccountStore((s) => s.signIn);
  const cancelSignIn = useAccountStore((s) => s.cancelSignIn);
  const signOut = useAccountStore((s) => s.signOut);
  const load = useAccountStore((s) => s.load);

  return (
    <Section title="Account">
      {/* A device flow that is out is what the section is about until it
          lands or is called off: the state it began from is the state it
          is trying to leave. */}
      {signingIn ? (
        <SettingRow
          label={ENDPOINT}
          // The code belongs to the row it is waiting on, not to a line
          // under it: the browser tab is already open, and the sentence is
          // what to do in it.
          description={
            userCode ? (
              <>
                A kendex.ai page just opened with the code{" "}
                <span className="font-mono font-medium text-foreground">
                  {userCode}
                </span>{" "}
                — approve it there and this page updates on its own.
              </>
            ) : (
              ACCOUNT_SIGNING_IN_NOTE
            )
          }
        >
          <Button variant="outline" onClick={cancelSignIn}>
            {ACCOUNT_CANCEL_SIGN_IN_LABEL}
          </Button>
        </SettingRow>
      ) : (
        accountRow(account, reading, readError, {
          signIn: () => void signIn(),
          signOut: () => void signOut(),
          load: () => void load(),
        })
      )}
      {/* The device flow's failure and the read's are two different things:
          a person who came back from denying an approval still has that
          explanation, whatever the read went on to say. */}
      {error ? (
        <p className="text-sm text-critical" role="alert">
          {error}
        </p>
      ) : null}
      {readError !== null ? (
        <SettingRow
          role="alert"
          label={
            <span className="text-critical">{ACCOUNT_UNREADABLE_LABEL}</span>
          }
          description={readError}
        >
          <Button
            variant="outline"
            disabled={reading}
            onClick={() => void load()}
          >
            {ACCOUNT_RETRY_LABEL}
          </Button>
        </SettingRow>
      ) : null}
    </Section>
  );
}
