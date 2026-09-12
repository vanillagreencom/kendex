// Why a marketplace page has no content to draw, decided once for every
// surface that draws it: the page's two content tabs and its header. The
// package page's own version of this question is `package-read-state.ts`.
import type { SourceReadRefused } from "@/bindings";
import { MARKETPLACE_NOT_DOWNLOADED } from "@/lib/copy-marketplaces";
import { isShapedRefusal, refusalWords } from "@/lib/refusal";
import { NO_REASON_GIVEN } from "@/lib/settled";

/** What stopped a marketplace read, as the surface has to say it.
 *
 * A subscription nothing has downloaded yet is the one answer that is not a
 * failure: the declaration is there, its mirror is empty, and asking again
 * answers the same. It gets its own case so a surface says it neutrally and
 * keeps its critical text — and its Try again, which would answer the same
 * — for a read that really went wrong. */
export type CatalogRefusal =
  | { is: "not-downloaded" }
  | { is: "failed"; reason: string };

/** How to say a catalog read's refusal, or null where there is none. One
 *  judge for every marketplace surface: the Bundles tab, the Packages tab
 *  and the header all read the same subscription, and a second copy of this
 *  test is two tabs disagreeing about whether the same marketplace has been
 *  downloaded.
 *
 *  A transport failure arrives as a bare string with no kind to read, the
 *  way `refusal.ts` says every folded message does, and lands as a failure
 *  — which is what it is. */
export const catalogRefusal = (
  refusal: SourceReadRefused | string | null | undefined,
): CatalogRefusal | null => {
  if (refusal === null || refusal === undefined) return null;
  if (isShapedRefusal(refusal) && refusal.kind === "source-pending") {
    return { is: "not-downloaded" };
  }
  return { is: "failed", reason: refusalWords(refusal) ?? NO_REASON_GIVEN };
};

/** The same refusal as one line, for a surface that states it in the one
 *  place it would state a failure: the bookmark list, the About tab, the
 *  offered-package page and the curated-set page each have a single slot.
 *  The marketplace's own page draws the two states apart and reads
 *  [catalogRefusal] instead. */
export const catalogRefusalLine = (
  refusal: SourceReadRefused | string | null | undefined,
): string | null => {
  const refused = catalogRefusal(refusal);
  if (refused === null) return null;
  return refused.is === "not-downloaded"
    ? MARKETPLACE_NOT_DOWNLOADED
    : refused.reason;
};
