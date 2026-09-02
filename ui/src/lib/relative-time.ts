// Coarse on purpose — the status footer only needs "how stale is this",
// not second-level precision. The steps below a month are that footer's and
// are unchanged; the two above it are for the commit dates the marketplace
// surfaces show, which are routinely years old and read as a day count
// without them ("731d ago" is not a date anybody parses).
//
// Coarse is only safe where the exact date is still reachable: "2y ago"
// alone loses the year entirely. Two shapes, and which one a site is
// decides how it keeps the date, because a sentence has no element of its
// own to carry it:
//
//   - A site RENDERING the reading uses `<Ago at={ms} />`
//     (components/ago.tsx), which is the reading and the title together and
//     cannot be had apart. Every such site goes through it; none adds the
//     attribute by hand, which is how two rounds of sweeps still left sites
//     without one.
//   - A site COMPOSING the reading into a sentence — the helpers below in
//     copy-projects, copy-updates and copy-safety — returns a string, so
//     the element that renders that sentence carries the title, built with
//     `exactTime` from the timestamp it already holds. project-card,
//     updates, safety-panel and status-footer are those four.
//
// `grep -rn 'relativeTime(' ui/src` is the list. It has been restated from
// memory twice and been wrong both times.
export function relativeTime(fromMs: number, toMs: number): string {
  const deltaSec = Math.max(0, Math.round((toMs - fromMs) / 1000));
  if (deltaSec < 60) return "just now";
  const deltaMin = Math.round(deltaSec / 60);
  if (deltaMin < 60) return `${deltaMin}m ago`;
  const deltaHour = Math.round(deltaMin / 60);
  if (deltaHour < 24) return `${deltaHour}h ago`;
  const deltaDay = Math.round(deltaHour / 24);
  if (deltaDay < 30) return `${deltaDay}d ago`;
  // Years floor rather than round: eighteen months is a year and a half,
  // and "2y ago" would age it past what the reading can support. The exact
  // date rides along on the `title` of every surface that shows this.
  const deltaYear = Math.floor(deltaDay / 365);
  if (deltaYear >= 1) return `${deltaYear}y ago`;
  // Never "12mo": a twelfth month is a year, and the branch above owns it.
  return `${Math.min(11, Math.round(deltaDay / 30.44))}mo ago`;
}

/** The exact moment behind a `relativeTime` reading, for the `title` of the
 *  element showing it. ISO-8601 in UTC: the value behind these is a
 *  filesystem timestamp, which carries no zone of its own to preserve.
 *
 *  A moment nothing can read answers `undefined`, so the element renders
 *  with no title rather than the caller having to remember: `toISOString`
 *  THROWS on NaN, and these timestamps come from a lock and a catalog,
 *  which is to say from strings nobody validated. The guard lives here
 *  because every caller would otherwise carry a copy of it, and the one
 *  that forgot crashed a page. */
export const exactTime = (atMs: number): string | undefined =>
  Number.isNaN(atMs) ? undefined : new Date(atMs).toISOString();
