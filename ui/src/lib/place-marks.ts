import type { Scope } from "@/bindings";
import {
  type PlaceStanding,
  standingIn,
  type Why,
} from "@/lib/customized-places";
import { placeName } from "@/lib/update-groups";

/** What a mark says, and where clicking it goes.
 *
 *  A badge that cannot be followed is a fact with no exit: the reader is
 *  told a place is theirs and left to find it. Every mark carries the
 *  place it named. */
export interface PlaceMark {
  label: string;
  /** The place the label names, which a click opens. Null when the mark
   *  is about no single place. */
  goTo: Scope | null;
  why: Why | null;
}

const customized = (s: PlaceStanding) => s.standing === "customized";

/** The Library row's mark: which places hold changes, out of how many.
 *
 *  Names the place while there is one to name — "Customized in vg" says
 *  more than "1 of 3 places" and is the answer to the question actually
 *  being asked. The count follows only when it adds something, and the
 *  bare word never appears alone. */
export function libraryMark(standings: PlaceStanding[]): PlaceMark | null {
  const all = standings.map((s) => s.scope);
  const mine = standings.filter(customized);
  if (mine.length === 0) return null;
  const unknown = standings.some((s) => s.standing === "unknown");
  if (mine.length === 1) {
    const only = mine[0];
    const where = placeName(only.scope, all);
    // With a place unread, "1 of 3" would be counting places nobody has
    // looked at — so the count is left off rather than guessed at.
    const label =
      standings.length === 1 || unknown
        ? `Customized in ${where}`
        : `Customized in ${where} · 1 of ${standings.length} places`;
    return { label, goTo: only.scope, why: only.why };
  }
  const named = mine.map((s) => placeName(s.scope, all)).join(" and ");
  const label = unknown
    ? `Customized in ${named}`
    : `Customized in ${named} · ${mine.length} of ${standings.length} places`;
  return { label, goTo: null, why: null };
}

/** The package header's mark: about the place the page is showing, and
 *  only that one. The header names a place, so its badge answers for the
 *  place it names rather than for the package everywhere. */
export function headerMark(
  standings: PlaceStanding[],
  scope: Scope,
): PlaceMark | null {
  const here = standingIn(standings, scope) ?? null;
  if (!here || !customized(here)) return null;
  return {
    label: `Customized in ${placeName(
      here.scope,
      standings.map((s) => s.scope),
    )}`,
    goTo: here.scope,
    why: here.why,
  };
}
