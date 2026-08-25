// Product prose for the safety surfaces. Split from copy.ts for the file
// line cap — same house style, same rules (see the top of copy.ts).
import type { Finding, Severity } from "@/bindings";
import { SEVERITY_LABELS } from "@/lib/labels";

// The check matches patterns over as much of a package as it reads. So every
// place a score is shown says what was determined and nothing more: a score
// with nothing behind it means nothing was matched, never that the package
// is safe to run. Sits under the score wherever one is shown — before an
// install and after it, since the reading is the same either way. It
// describes what the check did, never who wrote the package: this repo
// publishes a catalog of its own, so a claim about provenance is false for
// the items in it. Only a skill tree is read to a budget — every other kind
// reads whole — so the partial read is named as a skill's.
export const SAFETY_CAVEAT =
  "An automated check for risky patterns, not a review. It can miss things, and a package too large to read is not checked at all.";
const SEVERITY_ORDER: Severity[] = ["critical", "high", "medium", "low"];

/** The worst finding's severity, in the app's own words — what a dot's
 * colour or a badge's count stands for, so the words say it too. Any row
 * carrying a severity string qualifies; one that is not a safety severity
 * (a structural error or warning) has no word here. */
export function worstSeverityLabel(
  findings: { severity: string }[],
): string | null {
  const worst = SEVERITY_ORDER.find((severity) =>
    findings.some((finding) => finding.severity === severity),
  );
  return worst ? SEVERITY_LABELS[worst] : null;
}

// A list gives a package one dot and no line of its own, so the dot's words
// carry the worst severity and the caveat along with the number — worded
// as the package's own page words it. A row here installs without ever
// opening that page, and a bare score would be the assurance the check
// cannot give; a bare colour would be a severity nobody can read.
export const safetyDotWords = (
  score: number,
  skipped: number,
  findings: Finding[],
): string => {
  const severity = worstSeverityLabel(findings);
  const lead = severity
    ? `${severity} · `
    : skipped > 0
      ? "Not fully checked · "
      : "";
  return `${lead}${score}/100. ${SAFETY_CAVEAT}`;
};
// The same row installs before its score arrives, so the dot's words say
// there is no result rather than falling silent. A queued read and a failed
// one look alike from here, so this claims no check is under way — only that
// none has answered, which is the one thing true of both.
export const SAFETY_DOT_UNCHECKED = `Not checked yet. ${SAFETY_CAVEAT}`;
// The About tab's findings are about the catalog's own layout and
// configuration. Nothing here has read a single package.
export const CATALOG_LAYOUT_CLEAN =
  "Nothing wrong with how this catalog is put together.";

/** The dot's tone from what was found: severity is never color-only — the
 * words beside it carry the number and the caveat. */
export function severityTone(
  findings: Finding[],
): "good" | "warning" | "critical" {
  if (findings.some((finding) => finding.severity === "critical")) {
    return "critical";
  }
  return findings.length > 0 ? "warning" : "good";
}

/** The line under a score: the worst thing found and how many, or that
 *  nothing was. The severity is a word here and a wash of colour on the
 *  disc beside it, so the disc is never the only place it is said. A
 *  finding carrying a severity the safety ladder has no word for — a
 *  structural error or warning — leaves the count to speak alone. */
export function safetyHeadline(findings: Finding[], skipped: number): string {
  if (findings.length === 0) {
    return skipped > 0 ? "Nothing found in what was read" : "Nothing found";
  }
  const count = `${findings.length} finding${findings.length === 1 ? "" : "s"}`;
  const severity = worstSeverityLabel(findings);
  return severity ? `${severity} · ${count}` : count;
}

/** The same words for a row on the Updates page, where every other cell is
 *  about a version that is not installed yet. The score there is the copy
 *  on disk now, and saying so is what keeps the number from being read as
 *  the one the update would earn. */
export const installedScoreWords = (
  score: number,
  skipped: number,
  findings: Finding[],
): string =>
  `The copy installed now: ${safetyDotWords(score, skipped, findings)}`;
