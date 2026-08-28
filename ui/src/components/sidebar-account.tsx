import { CircleAlert, LogIn } from "lucide-react";
import type { ReactNode } from "react";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
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

/** What the row calls the account: the name the server answered with, or
 *  nothing where it has answered with none. `githubLogin` is not a second
 *  choice for it — the field is the provider's opaque account id, not a
 *  handle, and it is never shown. */
const displayName = (identity: AccountIdentity | null): string =>
  identity?.name.trim() ?? "";

/** The letter on the avatar, and nothing where there is no name to take it
 *  from. Split by code point so a first character outside the BMP survives
 *  being taken apart, and cased by the plain call rather than the
 *  locale-aware one, whose no-argument form is host-dependent by
 *  specification: the circle wants one glyph, the same everywhere. */
export function accountInitial(
  identity: AccountIdentity | null,
): string | null {
  const [first] = [...displayName(identity)];
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

/** One account row, and the one sentence behind it.
 *
 *  `tip` is the sentence: a popup for a pointer, the same popup for a
 *  keyboard because the trigger takes focus, and the trigger's own text for
 *  a screen reader. A native title reaches none of the last two, and on the
 *  failed-read row the sentence is the only place the reason lives.
 *
 *  A row with nowhere to go is still a trigger. It presses to nothing, which
 *  is the honest answer while the account cannot be read at all. */
function Row({
  onClick,
  tip,
  children,
}: {
  onClick?: () => void;
  tip: string;
  children: ReactNode;
}) {
  return (
    <Tooltip>
      <TooltipTrigger
        onClick={onClick}
        className={cn(
          SIDEBAR_ROW,
          "w-full text-sm text-muted-foreground outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50",
          onClick &&
            "transition-colors hover:bg-sidebar-accent/40 hover:text-foreground",
        )}
      >
        {children}
        <span className="sr-only">{tip}</span>
      </TooltipTrigger>
      <TooltipContent side="top" className="max-w-56">
        {tip}
      </TooltipContent>
    </Tooltip>
  );
}

/** The text column. It takes whatever the icon lane leaves and cuts a long
 *  name off rather than pushing the row wider than the sidebar. */
function Label({
  className,
  children,
}: {
  className?: string;
  children: ReactNode;
}) {
  return (
    <span className={cn("min-w-0 flex-1 truncate text-left", className)}>
      {children}
    </span>
  );
}

/** A row's sentence where the state's own explanation has to survive a
 *  later failed read. */
const explained = (sentence: string, readError: string | null): string =>
  readError === null ? sentence : `${sentence} ${readError}`;

/** Which row each account state draws.
 *
 *  The state decides on its own: a credential in the keychain is not a
 *  confirmed sign-in, so an unconfirmed one reads as offline and one the
 *  server has rejected asks to sign in again.
 *
 *  `readError` is why the last read did not land, and it outlives that read:
 *  a failure after an answer that worked leaves the settled state exactly as
 *  it was. Every row therefore carries the cause, or the failure would be
 *  visible before the first answer and invisible after it. Where the row's
 *  own sentence is the only explanation of what it draws, the cause joins it
 *  rather than replacing it: a rejected credential and a read that could not
 *  be made are different answers, and swapping one for the other would say
 *  the wrong thing about both. */
function accountRow(
  account: AccountState,
  readError: string | null,
  open: () => void,
): ReactNode {
  if (account.kind === "loading")
    // A read that failed says that much. One still on its way draws no row
    // rather than guessing which of the four answers is coming.
    return readError === null ? null : (
      <Row tip={readError}>
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
        <Row onClick={open} tip={readError ?? ACCOUNT_ROW_TITLE}>
          <LogIn className="size-[18px] shrink-0 opacity-70" />
          <Label>{ACCOUNT_SIGN_IN_LABEL}</Label>
        </Row>
      );
    case "expired":
      return (
        <Row onClick={open} tip={explained(ACCOUNT_EXPIRED_TITLE, readError)}>
          <LogIn className="size-[18px] shrink-0 opacity-70" />
          <Label>{ACCOUNT_SIGN_IN_AGAIN_LABEL}</Label>
        </Row>
      );
    case "signed-in":
      return (
        <Row onClick={open} tip={readError ?? ACCOUNT_ROW_TITLE}>
          <Avatar identity={account.identity} />
          <Label>
            {displayName(account.identity) || ACCOUNT_SIGNED_IN_LABEL}
          </Label>
        </Row>
      );
    case "offline":
      return (
        <Row onClick={open} tip={explained(ACCOUNT_OFFLINE_TITLE, readError)}>
          <Avatar identity={account.identity} />
          <Label>
            {displayName(account.identity) || ACCOUNT_SIGNED_IN_LABEL}
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
  return <div className="shrink-0 px-2 pb-2">{row}</div>;
}
