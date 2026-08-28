// What the app calls the account, and the letter that stands for it.
//
// Two surfaces draw an account — the sidebar's foot and Settings → Account —
// and one account must not read as two people, so the name and the letter
// are decided here rather than at each drawing.
import { ACCOUNT_SIGNED_IN_LABEL } from "@/lib/copy-account";
import { cn } from "@/lib/utils";
import type { AccountIdentity } from "@/stores/account";

/** The name the server answered with, or nothing where it has answered with
 *  none. `githubLogin` is not a second choice for it — the field is the
 *  provider's opaque account id, not a handle, and it is never shown. */
const displayName = (identity: AccountIdentity | null): string =>
  identity?.name.trim() ?? "";

/** What a row calls the account: the name, or that it is signed in where
 *  the server has answered with none. Every surface asks here, so a
 *  credential with no name behind it reads the same wherever it is drawn. */
export const accountLabel = (identity: AccountIdentity | null): string =>
  displayName(identity) || ACCOUNT_SIGNED_IN_LABEL;

/** What a reader would call the first character: a base letter with the
 *  marks that belong to it, an emoji with every part of its sequence, and a
 *  character outside the BMP whole rather than halved. Grapheme breaking
 *  does not turn on the locale, so the default one answers the same
 *  everywhere. */
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

const firstGrapheme = (text: string): string => {
  for (const { segment } of graphemes.segment(text)) return segment;
  return "";
};

/** The letter on the avatar, and nothing where there is no name to take it
 *  from.
 *
 *  Cased by the plain call rather than the locale-aware one, whose
 *  no-argument form is host-dependent by specification. Segmented again
 *  after casing because a case mapping can widen what it is given: the
 *  German sharp s uppercases to two letters, and the circle holds one. */
export function accountInitial(
  identity: AccountIdentity | null,
): string | null {
  const first = firstGrapheme(displayName(identity));
  return first ? firstGrapheme(first.toUpperCase()) : null;
}

/** The circle. It carries a letter once the server has named the account and
 *  stays empty until then: a stored credential is not a person, and
 *  inventing an initial for one would claim it is.
 *
 *  Size and type step come from the caller, because the two surfaces draw it
 *  at two sizes; everything that makes it the same circle stays here. */
export function AccountAvatar({
  identity,
  className,
}: {
  identity: AccountIdentity | null;
  className?: string;
}) {
  return (
    <span
      aria-hidden
      className={cn(
        "flex shrink-0 items-center justify-center rounded-full bg-foreground/[0.12] font-semibold leading-none",
        className,
      )}
    >
      {accountInitial(identity)}
    </span>
  );
}
