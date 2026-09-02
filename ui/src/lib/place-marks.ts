import type { Scope } from "@/bindings";
import type { PlaceStanding, Why } from "@/lib/customized-places";
import { listed } from "@/lib/listed";
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

/** What a counted set of places is called. Projects among themselves are
 *  projects; the personal scope makes the set a mixed one, and "places" is
 *  the word the rest of the app already uses for that. */
const placeWord = (scopes: Scope[]): string =>
  scopes.every((s) => s.scope === "project") ? "projects" : "places";

/** The mark for one package: which places hold changes, out of how many.
 *
 *  One rule wherever it is drawn. A Library row and the package's own
 *  header ask the same question about the same package, so a header that
 *  answered only for the place its page was opened at had the app
 *  contradicting itself — "3 of 3 places" on the row, "Customized in
 *  hyprtrade" on the page, both true by their own rule and neither saying
 *  which question it answered.
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
