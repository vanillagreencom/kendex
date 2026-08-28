import { CircleAlert, LogIn } from "lucide-react";
import type { ReactNode } from "react";
import {
  ACCOUNT_EXPIRED_TITLE,
  ACCOUNT_OFFLINE_LABEL,
  ACCOUNT_OFFLINE_TITLE,
  ACCOUNT_ROW_TITLE,
  ACCOUNT_SIGN_IN_AGAIN_LABEL,
  ACCOUNT_SIGN_IN_LABEL,
  ACCOUNT_SIGNED_IN_LABEL,
  ACCOUNT_UNREADABLE_LABEL,
} from "@/lib/copy";
import { SIDEBAR_ROW } from "@/lib/layout";
import { cn } from "@/lib/utils";
import {
  type AccountIdentity,
  type AccountState,
  useAccountStore,
} from "@/stores/account";
import { useNavStore } from "@/stores/nav";

/** The letter on the avatar: the name's first, the handle's where there is
 *  no name, and nothing where the account has neither. A blank name is no
 *  name, which is why the fallback runs on the empty string as well as on a
 *  missing one. Split by code point so a first character outside the BMP
 *  survives being taken apart, and cased without the runtime's locale: the
 *  circle wants one glyph, and a Turkish locale cases an 'i' into a
 *  dotted capital instead. */
export function accountInitial(
  identity: AccountIdentity | null,
): string | null {
  const source = identity?.name?.trim() || identity?.githubLogin.trim() || "";
  const [first] = [...source];
  return first ? first.toUpperCase() : null;
}

/** The circle in the icon lane. It carries a letter once the server has
 *  named the account and stays empty until then: a stored credential is not
 *  a person, and inventing an initial for one would claim it is. */
function Avatar({ identity }: { identity: AccountIdentity | null }) {
  return (
    <span
      aria-hidden
      className="flex size-[18px] shrink-0 items-center justify-center rounded-full bg-foreground/[0.12] text-[10px] font-semibold leading-none"
    >
      {accountInitial(identity)}
    </span>
  );
}

/** One account row. A button wherever there is somewhere to go, plain text
 *  where the app has nothing to offer. */
function Row({
  onClick,
  title,
  children,
}: {
  onClick?: () => void;
  title?: string;
  children: ReactNode;
}) {
  const shape = cn(SIDEBAR_ROW, "w-full text-sm text-muted-foreground");
  if (!onClick)
    return (
      <div className={shape} title={title}>
        {children}
      </div>
    );
  return (
    <button
      type="button"
      onClick={onClick}
      title={title}
      className={cn(
        shape,
        "transition-colors hover:bg-sidebar-accent/40 hover:text-foreground",
      )}
    >
      {children}
    </button>
  );
}

/** The text column. It takes whatever the icon lane leaves and cuts a long
 *  handle off rather than pushing the row wider than the sidebar. */
function Label({
  mono,
  title,
  className,
  children,
}: {
  mono?: boolean;
  /** What a truncated line says in full. A handle wide enough to be cut is
   *  the only line here long enough to need it. */
  title?: string;
  className?: string;
  children: ReactNode;
}) {
  return (
    <span
      title={title}
      className={cn(
        "min-w-0 flex-1 truncate text-left",
        mono && "font-mono",
        className,
      )}
    >
      {children}
    </span>
  );
}

/** Which row each account state draws.
 *
 *  The state decides on its own: a credential in the keychain is not a
 *  confirmed sign-in, so an unconfirmed one reads as offline and one the
 *  server has rejected asks to sign in again.
 *
 *  `readError` is why the last read did not land, and it outlives that read:
 *  a failure after an answer that worked leaves the settled state exactly as
 *  it was. Every row therefore says the cause in place of the sentence it
 *  would otherwise carry, or the failure would be visible before the first
 *  answer and invisible after it. */
function accountRow(
  account: AccountState,
  readError: string | null,
  open: () => void,
): ReactNode {
  if (account.kind === "loading")
    // A read that failed says that much. One still on its way draws no row
    // rather than guessing which of the four answers is coming.
    return readError === null ? null : (
      <Row title={readError}>
        <CircleAlert className="size-[18px] shrink-0 opacity-70" />
        {/* The only line long enough to need the smaller step: at the nav's
            size it would truncate inside a 224px column, and half a
            sentence about a failure is worse than none. */}
        <Label className="text-xs">{ACCOUNT_UNREADABLE_LABEL}</Label>
      </Row>
    );

  switch (account.kind) {
    case "signed-out":
      return (
        <Row onClick={open} title={readError ?? ACCOUNT_ROW_TITLE}>
          <LogIn className="size-[18px] shrink-0 opacity-70" />
          <Label>{ACCOUNT_SIGN_IN_LABEL}</Label>
        </Row>
      );
    case "expired":
      return (
        <Row onClick={open} title={readError ?? ACCOUNT_EXPIRED_TITLE}>
          <LogIn className="size-[18px] shrink-0 opacity-70" />
          <Label>{ACCOUNT_SIGN_IN_AGAIN_LABEL}</Label>
        </Row>
      );
    case "signed-in": {
      const handle = account.identity?.githubLogin.trim();
      return (
        <Row onClick={open} title={readError ?? ACCOUNT_ROW_TITLE}>
          <Avatar identity={account.identity} />
          <Label mono={Boolean(handle)} title={handle}>
            {handle || ACCOUNT_SIGNED_IN_LABEL}
          </Label>
        </Row>
      );
    }
    case "offline":
      return (
        <Row onClick={open} title={readError ?? ACCOUNT_OFFLINE_TITLE}>
          <Avatar identity={account.identity} />
          <Label mono title={account.identity.githubLogin}>
            {account.identity.githubLogin}
          </Label>
          <span className="shrink-0 text-xs">{ACCOUNT_OFFLINE_LABEL}</span>
        </Row>
      );
  }

  // A sixth account state has to be drawn above before this compiles.
  const undrawn: never = account;
  return undrawn;
}

/**
 * The foot of the sidebar: who the last account read found, and the way in
 * to the account settings.
 *
 * Nothing here retries a read. The startup effect in `App.tsx` owns that,
 * reading again every time the window comes back, so a failure that was the
 * network's clears itself when the person returns to the app.
 */
export function SidebarAccount() {
  const account = useAccountStore((s) => s.account);
  const readError = useAccountStore((s) => s.readError);
  const goTo = useNavStore((s) => s.goTo);

  const row = accountRow(account, readError, () => goTo("settings"));
  if (row === null) return null;
  return <div className="px-2 pb-2">{row}</div>;
}
