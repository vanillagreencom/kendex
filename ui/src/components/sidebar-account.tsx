import { CircleAlert, LogIn } from "lucide-react";
import type { ReactNode } from "react";
import { AccountAvatar, displayName } from "@/components/account-avatar";
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
} from "@/lib/copy-account";
import { SIDEBAR_ROW } from "@/lib/layout";
import { cn } from "@/lib/utils";
import { type AccountState, useAccountStore } from "@/stores/account";
import { useNavStore } from "@/stores/nav";

/** One account row, and the one sentence behind it.
 *
 *  `tip` is the sentence: a popup for a pointer, the same popup for a
 *  keyboard because the trigger takes focus, and the trigger's own text for
 *  a screen reader. A native title reaches none of the last two.
 *
 *  Every row acts, including the one a failed read leaves: what it opens is
 *  the page carrying the reason and the retry. */
function Row({
  onClick,
  tip,
  children,
}: {
  onClick: () => void;
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

/** Which row each account state draws.
 *
 *  The state decides on its own: a credential in the keychain is not a
 *  confirmed sign-in, so an unconfirmed one reads as offline and one the
 *  server has rejected asks to sign in again.
 *
 *  `readError` is why the last read did not land, and the row reports only
 *  that it happened. The reason and the retry belong to Settings > Account,
 *  which every row opens: a sidebar row is one line wide, and a failure
 *  explained in two places is a failure explained differently in two
 *  places. A read that fails after one that landed leaves the settled state
 *  exactly as it was, so those rows go on saying what they said. */
function accountRow(
  account: AccountState,
  readError: string | null,
  open: () => void,
): ReactNode {
  if (account.kind === "loading")
    // A read that failed says that much. One still on its way draws no row
    // rather than guessing which of the four answers is coming.
    return readError === null ? null : (
      <Row onClick={open} tip={ACCOUNT_ROW_TITLE}>
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
        <Row onClick={open} tip={ACCOUNT_ROW_TITLE}>
          <LogIn className="size-[18px] shrink-0 opacity-70" />
          <Label>{ACCOUNT_SIGN_IN_LABEL}</Label>
        </Row>
      );
    case "expired":
      return (
        <Row onClick={open} tip={ACCOUNT_EXPIRED_TITLE}>
          <LogIn className="size-[18px] shrink-0 opacity-70" />
          <Label>{ACCOUNT_SIGN_IN_AGAIN_LABEL}</Label>
        </Row>
      );
    case "signed-in":
      return (
        <Row onClick={open} tip={ACCOUNT_ROW_TITLE}>
          <AccountAvatar
            identity={account.identity}
            className="size-[18px] text-[10px]"
          />
          <Label>
            {displayName(account.identity) || ACCOUNT_SIGNED_IN_LABEL}
          </Label>
        </Row>
      );
    case "offline":
      return (
        <Row onClick={open} tip={ACCOUNT_OFFLINE_TITLE}>
          <AccountAvatar
            identity={account.identity}
            className="size-[18px] text-[10px]"
          />
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
 * to the account settings, which is where a failed read is explained and
 * retried.
 *
 * Nothing here retries a read on its own. The startup effect in `App.tsx`
 * reads again every time the window comes back, so a failure that was the
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
