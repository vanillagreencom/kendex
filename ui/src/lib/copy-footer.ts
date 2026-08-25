// Status footer copy: the always-mounted strip's scan status — kept apart
// from the rest so the wording is reviewed in one place.

// What the last scan is telling you.
export const SCANNING_LABEL = "Scanning…";
export const scanStatusLabel = (scannedAgo: string | null): string =>
  scannedAgo ? `Up to date · scanned ${scannedAgo}` : "Up to date";
// "Up to date" beside a scan that failed would have the footer and Home
// answering the same question oppositely: a failed first scan is a failed
// status, and a kept result is last-known, not current.
export const scanFailedStatusLabel = (scannedAgo: string | null): string =>
  scannedAgo ? `Couldn't scan · last scanned ${scannedAgo}` : "Couldn't scan";
