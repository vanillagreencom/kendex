/** How a package's own words are shown where the room for them is bounded.
 *
 *  The Library row clamps to two lines in CSS, which is what the row has
 *  space for. A preview has more room but not unlimited room, and an
 *  author may write a paragraph: past this much the preview stops and
 *  offers the package's page, which shows the whole thing. One rule, so
 *  the "More" that appears and the text it appears under can never
 *  disagree about whether anything was left out.
 */

/** How much of an author's summary a preview shows, counted in characters
 *  — code points, not the units a JavaScript string is stored in. Chosen
 *  for about six lines at the preview's width — long enough that a written
 *  summary arrives whole, short enough that a page of prose does not become
 *  a popup. */
export const PREVIEW_SUMMARY_CHARS = 280;

/** A summary as a preview shows it. */
export interface PreviewSummary {
  /** The text to draw. */
  shown: string;
  /** Whether anything was left out, which is what puts More on screen. */
  truncated: boolean;
}

/** The summary a preview draws, cut at a word where it is too long for
 *  one. The cut lands on the last space before the bound, so a preview
 *  never ends mid-word; a single word longer than the bound is cut where
 *  the bound falls, since there is no space to cut at.
 *
 *  Measured and cut in characters. A string indexes in UTF-16 units, and
 *  anything past the basic plane — an emoji in a summary, most obviously —
 *  is two of them, so a bound counted in units can fall between the halves
 *  of one character and leave half of it on screen. */
export function previewSummary(summary: string): PreviewSummary {
  const text = summary.trim();
  const characters = [...text];
  if (characters.length <= PREVIEW_SUMMARY_CHARS) {
    return { shown: text, truncated: false };
  }
  const window = characters.slice(0, PREVIEW_SUMMARY_CHARS).join("");
  const lastSpace = window.lastIndexOf(" ");
  // A space is one unit and one character, so cutting at one splits
  // nothing.
  const cut = lastSpace > 0 ? window.slice(0, lastSpace) : window;
  return { shown: `${cut.trimEnd()}…`, truncated: true };
}
