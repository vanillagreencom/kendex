// Product prose for the safety surfaces. Split from copy.ts for the file
// line cap — same house style, same rules (see the top of copy.ts).
import type { Finding, Severity } from "@/bindings";
import { SEVERITY_LABELS } from "@/lib/labels";
import { relativeTime } from "@/lib/relative-time";

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

// The package page's own tab for the reading. The score follows these
// words on the tab itself, so the tab never says the number twice.
export const SAFETY_TAB = "Safety score";
// What the tab's figure is when a reading outlives the check meant to
// replace it. Short enough to sit on a tab, and it is the accessible name
// for the mark beside it: a colour and an icon alone would leave a kept
// number reading as a current one.
export const SAFETY_TAB_STALE = "the last reading kendex could check";
// The same job where the failure left nothing behind it. Overview is the
// tab a page opens on, so without this the only sign of a check that never
// ran is a dash — which is also what pending and unscored show.
export const SAFETY_TAB_FAILED = "the check couldn't run";
// The audit is the slowest thing the app does, so the tab opens before it
// has answered. A wait is not an outcome, and this says which it is.
export const SAFETY_CHECKING = "Checking this package…";
// Content a tool ships itself is never scored: the audit skips it, because
// the reader did not choose it and cannot change it. That is a settled
// answer rather than a reading still to come, so the tab says which — the
// unscored state's retry would ask for a check that is not coming.
export const SAFETY_VENDOR = "Shipped with the harness";
// The audit answered and had no reading for this package. Nothing found and
// nothing read are different claims, and only the second one is true here.
export const SAFETY_NOT_READ = "This package hasn't been scored";
export const SAFETY_NOT_READ_BODY =
  "The last check answered without a reading for it. Ask for a new check to get one.";
const SEVERITY_ORDER: Severity[] = ["critical", "high", "medium", "low"];

/** How bad the worst finding is, as a number that only ever gets compared:
 * higher is worse, and a list with nothing in it is 0. The ladder is the
 * one `worstSeverityLabel` reads, so the words and the ranking can never
 * disagree. Findings carrying a severity that is not on the ladder rank at
 * the floor, the same as no finding at all. */
export function worstSeverityRank(findings: { severity: string }[]): number {
  return findings.reduce((worst, finding) => {
    const place = SEVERITY_ORDER.indexOf(finding.severity as Severity);
    return place === -1
      ? worst
      : Math.max(worst, SEVERITY_ORDER.length - place);
  }, 0);
}

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

// What a kept reading is, wherever a score outlives the check that would
// have replaced it. Without this the app presents a number as current when
// nothing current exists — and without the age, a reader cannot tell a
// number from a minute ago from one from last week. The word "safety" is
// spelled around throughout this file: it contains "safe", and no copy
// beside a score may say that.
//
// `checkedAt` is null only where nothing ever answered, which leaves the
// age genuinely unknown rather than something to guess at.
export const staleSafetyNote = (
  checkedAt: number | null,
  now: number = Date.now(),
): string =>
  checkedAt === null
    ? "The last check couldn't run. This reading is from an earlier one."
    : `The last check couldn't run. This reading was taken ${relativeTime(
        checkedAt,
        now,
      )}.`;
/** The same thing in a tooltip, where the score follows it on one line. */
const staleSafetyLead = (
  checkedAt: number | null,
  now: number = Date.now(),
): string =>
  checkedAt === null
    ? "The last check couldn't run. From an earlier one:"
    : `The last check couldn't run. From the reading taken ${relativeTime(
        checkedAt,
        now,
      )}:`;
// No reading at all, and the check is over rather than pending — so this
// comes with something to press instead of a spinner.
export const SAFETY_CHECK_FAILED =
  "The check couldn't run, so nothing here has been scored.";
export const SAFETY_RETRY_LABEL = "Try again";

/** The same words for a row on the Updates page, where every other cell is
 *  about a version that is not installed yet. The score there is the copy
 *  on disk now, and saying so is what keeps the number from being read as
 *  the one the update would earn — unless the last check failed, when what
 *  it is is the reading before that one. */
export const installedScoreWords = (
  score: number,
  skipped: number,
  findings: Finding[],
  /** Set where the check after this reading failed: the number stays, but
   *  it stops being what the files say now. */
  stale = false,
  /** When this reading was taken, for the stale wording to date it. */
  checkedAt: number | null = null,
  now: number = Date.now(),
): string =>
  `${
    stale ? staleSafetyLead(checkedAt, now) : "The copy installed now:"
  } ${safetyDotWords(score, skipped, findings)}`;
