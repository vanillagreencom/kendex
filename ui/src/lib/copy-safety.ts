// Product prose for the safety surfaces. Split from copy.ts for the file
// line cap — same house style, same rules (see the top of copy.ts).
import type { Finding } from "@/bindings";

// The check matches patterns over as much of a package as it reads. So every
// place a score is shown says what was determined and nothing more: a score
// with nothing behind it means nothing was matched, never that the package
// is safe to run.
export const SAFETY_SECTION_EXPLAINER =
  "kendex looks for risky patterns in each package. It is an automated check rather than a review, it can miss things, and a package too large to read is not checked at all. Nothing is held back over it.";
// Sits under the score on the page where somebody decides to install.
// It describes what the check did, never who wrote the package: this repo
// publishes a catalog of its own, so a claim about provenance is false for
// the items in it. Only a skill tree is read to a budget — every other kind
// reads whole — so the partial read is named as a skill's.
export const PREINSTALL_SAFETY_CAVEAT =
  "An automated check for risky patterns, not a review. It can miss things, and a package too large to read is not checked at all.";
// A list gives a package one dot and no line of its own, so the dot's words
// carry the caveat along with the number — worded as the package's own page
// words it. A row here installs without ever opening that page, and a bare
// score would be the assurance the check cannot give.
export const safetyDotWords = (
  score: number,
  skipped: number,
  findings: Finding[],
): string =>
  `${findings.length === 0 && skipped > 0 ? "Not fully checked · " : ""}${score}/100. ${PREINSTALL_SAFETY_CAVEAT}`;
// The same row installs before its score arrives, so the dot's words say
// there is no result rather than falling silent. A queued read and a failed
// one look alike from here, so this claims no check is under way — only that
// none has answered, which is the one thing true of both.
export const SAFETY_DOT_UNCHECKED = `Not checked yet. ${PREINSTALL_SAFETY_CAVEAT}`;
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
