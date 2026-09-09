import type { Scope } from "@/bindings";
import type { PlaceStanding, Why } from "@/lib/customized-places";
import { listed } from "@/lib/listed";
import { placeWord } from "@/lib/place-word";
import { placeName } from "@/lib/update-groups";

/** What a mark says, and where it leads if anywhere. */
export interface PlaceMark {
  label: string;
  /** The place a click opens, where opening one is worth offering.
   *
   *  Null when the mark names several places, so no one of them is the
   *  destination. A caller already standing in the place a single-place
   *  mark names ignores this rather than offering a way back to where the
   *  reader stands. */
  goTo: Scope | null;
  why: Why | null;
}

const customized = (s: PlaceStanding) => s.standing === "customized";

/** The mark for one package: which places hold changes, out of how many.
 *
 *  One rule for the one surface that draws it, the package page's header,
 *  and it answers for the package over every place, not for the place the
 *  page happened to open at: "Customized in hyprtrade" would be true by
 *  that place's rule and silent about the rest.
 *
 *  Names the place while there is one to name — "Customized in vg" says
 *  more than "1 of 3 places" and is the answer to the question actually
 *  being asked. The count follows only when it adds something, and the
 *  bare word never appears alone. */
export function packageMark(standings: PlaceStanding[]): PlaceMark | null {
  const all = standings.map((s) => s.scope);
  const mine = standings.filter(customized);
  if (mine.length === 0) return null;
  const unknown = standings.some((s) => s.standing === "unknown");
  const named = listed(mine.map((s) => placeName(s.scope, all)));
  // With a place unread, "1 of 3" would be counting places nobody has
  // looked at — so the count is left off rather than guessed at.
  const label =
    standings.length === 1 || unknown
      ? `Customized in ${named}`
      : `Customized in ${named} · ${mine.length} of ${standings.length} ${placeWord(all)}`;
  const only = mine.length === 1 ? mine[0] : null;
  return { label, goTo: only?.scope ?? null, why: only?.why ?? null };
}
