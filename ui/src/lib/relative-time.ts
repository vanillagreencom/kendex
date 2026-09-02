// Coarse on purpose — the status footer only needs "how stale is this",
// not second-level precision. The steps below a month are that footer's and
// are unchanged; the two above it are for the commit dates the marketplace
// surfaces show, which are routinely years old and read as a day count
// without them ("731d ago" is not a date anybody parses).
//
// Coarse is only safe where the exact date is still reachable, so every
// surface that shows a year or a month puts it on the element's `title`:
// "2y ago" alone loses the year entirely. A surface holding the original
// string passes that; one holding a timestamp uses `exactTime` below.
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
 *  filesystem timestamp, which carries no zone of its own to preserve. */
export const exactTime = (atMs: number): string => new Date(atMs).toISOString();
