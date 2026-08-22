// Product prose for the safety surfaces: the decision zone, the held-back
// panel, accepting findings, and taking over a shared folder. Split from copy.ts for the file line cap — same house style,
// same rules (see the top of copy.ts).
import type { DismissReason, Verdict } from "@/bindings";
import { REASON_LABELS } from "@/lib/copy-decisions";
import { VERDICT_LABELS } from "@/lib/labels";

// The zone only a person can clear: held-back installs first, then the
// findings nobody has ruled on. Its caption counts both halves.
export const DECISION_ZONE_TITLE = "Needs your decision";
// A conflict has no ops behind it: Apply cannot clear it, and the exits it
// does have live on the package's own page.
export const CONFLICT_ZONE_TITLE = "Waiting on you, on their own pages";
export const cleanSummaryLead = (total: number): string =>
  `${total} item${total === 1 ? "" : "s"}, nothing to report`;
export const settledSummaryLead = (count: number, byAuthor = 0): string => {
  const noun = `${count} finding${count === 1 ? "" : "s"} already decided`;
  return byAuthor > 0 ? `${noun} (${byAuthor} by the publisher)` : noun;
};

// What a package's publisher already ruled on. Named as theirs every time:
// the person reading this did not make these calls, and a line that let
// them read as their own would be the one dishonest thing on the page.
export const publisherSettledLabel = (count: number): string =>
  `${count} finding${count === 1 ? "" : "s"} the publisher already reviewed`;
export const publisherSettledExplainer =
  "Recorded by whoever publishes these items, against exactly these bytes. Reported here and not counted toward the score — edit the item and they come back.";
export const publisherSettledNote = (
  publisher: string,
  reason: DismissReason,
  when: string | null,
): string =>
  `${publisher} reviewed this${when ? ` ${when}` : ""} — ${REASON_LABELS[
    reason
  ].toLowerCase()}`;

export const SAFETY_HELP =
  "Strict catches more, and flags more things that turn out fine. Lenient stops only the riskiest.";

// The check matches patterns over as much of a package as it reads. So every
// place a verdict is shown says what was determined and nothing more: a
// verdict with nothing in it means nothing was matched, never that the
// package is safe to run.
export const SAFETY_SECTION_EXPLAINER =
  "kendex looks for risky patterns in each package before it installs. It is an automated check rather than a review. It can miss things, and a large skill is read only in part.";
// Sits under the verdict on the page where somebody decides to install.
// It describes what the check did, never who wrote the package: this repo
// publishes a catalog of its own, so a claim about provenance is false for
// the items in it. Only a skill tree is read to a budget — every other kind
// reads whole — so the partial read is named as a skill's.
export const PREINSTALL_SAFETY_CAVEAT =
  "An automated check for risky patterns, not a review. It can miss things, and a large skill is read only in part.";
// A list gives a package one dot and no line of its own, so the dot's words
// carry the caveat along with the number — worded as the package's own page
// words it. A row here installs without ever opening that page, and a bare
// score would be the assurance the check cannot give.
export const safetyDotWords = (verdict: Verdict, score: number): string =>
  `${VERDICT_LABELS[verdict]} · ${score}/100. ${PREINSTALL_SAFETY_CAVEAT}`;
// The same row installs before its score arrives, so the dot's words say
// there is no result rather than falling silent. A queued read and a failed
// one look alike from here, so this claims no check is under way — only that
// none has answered, which is the one thing true of both.
export const SAFETY_DOT_UNCHECKED = `Not checked yet. ${PREINSTALL_SAFETY_CAVEAT}`;
// The About tab's findings are about the catalog's own layout and
// configuration. Nothing here has read a single package.
export const CATALOG_LAYOUT_CLEAN =
  "Nothing wrong with how this catalog is put together.";

// This list scores what is on disk right now, not what a plan would write —
// so every row here is a thing the harnesses will load the next time they start.
// "Held back" describes what kendex refuses to do with it, and must never be
// read as "this isn't on your machine".
export const BLOCKED_SECTION_EXPLAINER =
  "Not installed or updated until you accept what was found. Copies already on your machine keep running.";
// The row for an install the gate stopped before it ever reached disk.
export const HELD_BACK_NOT_ON_DISK_NOTE =
  "Not installed — kendex stopped this one before it landed.";

// Accepting a held-back item. The action is reading the findings and
// choosing to install anyway; the record lands in a manifest, and *which*
// manifest decides who inherits the decision — so the dialog words the
// consequence per scope and claims nothing else.
export const ACCEPT_BLOCKED_LABEL = "Accept and install…";
// A held-back row the next apply would not write — an item already on the
// machine that kendex does not install. There is nothing to let through.
export const NOTHING_TO_ACCEPT =
  "Nothing to accept — kendex isn't installing this one. Remove it from the Library if you don't want it.";
export const ACCEPT_BLOCKED_TITLE = "Accept these findings?";
export const acceptBlockedBody = (projectScope: boolean): string =>
  projectScope
    ? "Saved into this project's kendex.toml, so anyone using the repository inherits it. It covers this version only — if the file changes, the block comes back."
    : "Saved in your personal manifest on this machine. It covers this version only — if the file changes, the block comes back.";
export const ACCEPT_BLOCKED_CONFIRM = "Accept and install";

// Withdrawing an acceptance, from the recorded-decisions list.
export const WITHDRAW_LABEL = "Withdraw";

// Taking over a folder that several harnesses read through links. The dialog
// names the real folder and every harness kendex knows is reading it; the
// last sentence is the one honest warning — links kendex cannot see will
// break, and there is no way to list them.
export const ADOPT_SHARED_TITLE = "Take over this shared folder?";
export const adoptSharedBody = (target: string, harnesses: string[]): string =>
  `${harnesses.join(" and ")} read this skill from ${target}. kendex moves the folder's content into its own keeping (the folder goes to the trash, recoverable) and gives each harness listed a link to kendex's copy, so they stay in sync. Anything else that points at the old folder will stop working.`;
export const ADOPT_SHARED_CONFIRM = "Take it over";
