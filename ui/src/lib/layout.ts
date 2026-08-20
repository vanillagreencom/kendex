// One horizontal rhythm for every page. Gutters shrink on small windows and
// open up on very large ones instead of sitting at a fixed 2rem forever.
export const PAGE_GUTTER = "px-5 md:px-8 2xl:px-12";

/** A page's scrolling body: the shared gutters plus its vertical breathing room. */
export const PAGE_BODY = `py-8 ${PAGE_GUTTER}`;

// Reading pages cap at a comfortable measure. Data-dense pages — the Library
// table — take the window instead, since a table with room for its columns
// beats one truncating inside a column of empty margin; the cap only stops
// rows from stretching so wide the eye loses the line on an ultrawide screen.
export const CONTENT_WIDTH = "mx-auto w-full max-w-3xl";
export const WIDE_CONTENT_WIDTH = "mx-auto w-full max-w-[110rem]";

// Which pages take the window rather than the reading measure. The
// breadcrumb strip sits outside any page and has to match the one below it,
// so the choice is named here rather than passed down twice.
const WIDE_PAGES = new Set([
  "library",
  "updates",
  "package",
  "marketplaces",
  "marketplaceDetail",
  "availablePackage",
]);

export function isWidePage(page: string): boolean {
  return WIDE_PAGES.has(page);
}
